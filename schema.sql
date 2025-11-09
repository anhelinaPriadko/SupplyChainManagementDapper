--
-- PostgreSQL database dump
--

\restrict 6kEvsNQSM87bIbLSFt125AGTDAVheCxwk6iGUUhGZ8DO7Je22BOzHlq32RnNNce

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: checkuseractivitybeforeupdate(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.checkuseractivitybeforeupdate() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Перевірка поля updated_by в NEW-записі
    IF NOT IsUserActive(NEW.updated_by) THEN
        RAISE EXCEPTION 'Користувач (ID: %) неактивний і не може оновлювати записи.', NEW.updated_by;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.checkuseractivitybeforeupdate() OWNER TO postgres;

--
-- Name: create_purchase_order(integer, date, integer, jsonb); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.create_purchase_order(IN p_supplier_id integer, IN p_order_date date, IN p_created_by integer, IN p_items jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_po_id integer;
  item jsonb;
  v_product_id integer;
  v_ordered_qty numeric;
  v_unit_price numeric;
BEGIN
  -- Створюємо PO
  INSERT INTO purchase_orders(supplier_id, order_date, status, total_amount, created_at, updated_at, updated_by)
  VALUES (p_supplier_id, p_order_date, 'Created', 0, now(), now(), p_created_by)
  RETURNING po_id INTO v_po_id;

  -- Перебираємо елементи з підтримкою snake_case, camelCase та PascalCase
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := COALESCE(
        (item ->> 'product_id')::int,
        (item ->> 'productId')::int,
        (item ->> 'ProductId')::int
    );

    v_ordered_qty := COALESCE(
        (item ->> 'ordered_quantity')::numeric,
        (item ->> 'orderedQuantity')::numeric,
        (item ->> 'OrderedQuantity')::numeric
    );

    v_unit_price := COALESCE(
        (item ->> 'unit_price')::numeric,
        (item ->> 'unitPrice')::numeric,
        (item ->> 'UnitPrice')::numeric,
        0::numeric
    );

    -- Валідація
    IF v_product_id IS NULL THEN
      RAISE EXCEPTION 'Missing product_id in PO items (one of product_id/productId/ProductId required). Item: %', item::text;
    END IF;
    IF v_ordered_qty IS NULL OR v_ordered_qty <= 0 THEN
      RAISE EXCEPTION 'Invalid ordered quantity for product %: %', v_product_id, v_ordered_qty;
    END IF;

    -- Вставляємо позицію
    INSERT INTO po_items(po_id, product_id, ordered_quantity, unit_price)
    VALUES (v_po_id, v_product_id, v_ordered_qty, v_unit_price);
  END LOOP;

  -- Оновлюємо total_amount
  UPDATE purchase_orders
  SET total_amount = (SELECT COALESCE(SUM(ordered_quantity * unit_price),0) FROM po_items WHERE po_id = v_po_id)
  WHERE po_id = v_po_id;
END;
$$;


ALTER PROCEDURE public.create_purchase_order(IN p_supplier_id integer, IN p_order_date date, IN p_created_by integer, IN p_items jsonb) OWNER TO postgres;

--
-- Name: create_shipment(integer, integer, integer, date, character varying, integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.create_shipment(IN p_so_id integer, IN p_carrier_id integer, IN p_warehouse_id integer, IN p_shipping_date date, IN p_tracking_number character varying, IN p_user_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
  r_item RECORD;
  v_location_id integer;
  v_available numeric;
  v_qty_to_ship numeric;
  v_shipment_id integer;
BEGIN
  -- знайти DEFAULT локацію для складу
  SELECT location_id INTO v_location_id
  FROM warehouse_locations
  WHERE warehouse_id = p_warehouse_id AND location_code = 'DEFAULT'
  LIMIT 1;

  IF v_location_id IS NULL THEN
    RAISE EXCEPTION 'No DEFAULT location for warehouse %', p_warehouse_id;
  END IF;

  -- перевірити, що SO існує
  IF NOT EXISTS (SELECT 1 FROM sales_orders WHERE so_id = p_so_id) THEN
    RAISE EXCEPTION 'Sales order % not found', p_so_id;
  END IF;

  -- Для кожного айтему SO перевірити наявність і списати
  FOR r_item IN
    SELECT product_id, ordered_quantity, shipped_quantity
    FROM so_items
    WHERE so_id = p_so_id
  LOOP
    v_qty_to_ship := (r_item.ordered_quantity - COALESCE(r_item.shipped_quantity,0));
    IF v_qty_to_ship <= 0 THEN
      CONTINUE;
    END IF;

    -- Блокуємо рядок current_inventory
    SELECT quantity INTO v_available
    FROM current_inventory
    WHERE product_id = r_item.product_id AND location_id = v_location_id
    FOR UPDATE;

    IF v_available IS NULL OR v_available < v_qty_to_ship THEN
      RAISE EXCEPTION 'Not enough stock for product % (need %, have %)', r_item.product_id, v_qty_to_ship, COALESCE(v_available,0);
    END IF;

    -- зменшити current_inventory
    UPDATE current_inventory
    SET quantity = quantity - v_qty_to_ship
    WHERE product_id = r_item.product_id AND location_id = v_location_id;

    -- записати в inventory_history (використовуємо negative change)
    INSERT INTO inventory_history(product_id, location_id_from, location_id_to, quantity_change, operation_type, related_document_id, movement_date)
    VALUES (r_item.product_id, v_location_id, NULL, -v_qty_to_ship, 'SHIP', p_so_id, p_shipping_date);

    -- оновити shipped_quantity
    UPDATE so_items
    SET shipped_quantity = COALESCE(shipped_quantity,0) + v_qty_to_ship
    WHERE so_id = p_so_id AND product_id = r_item.product_id;
  END LOOP;

  -- створити запис shipment
  INSERT INTO shipments(so_id, carrier_id, warehouse_id, shipping_date, tracking_number, status, created_at, updated_at, updated_by)
  VALUES (p_so_id, p_carrier_id, p_warehouse_id, p_shipping_date, p_tracking_number, 'Shipped', now(), now(), p_user_id)
  RETURNING shipment_id INTO v_shipment_id;

  -- оновити статус sales_orders
  UPDATE sales_orders
  SET status = 'Shipped', updated_at = now(), updated_by = p_user_id
  WHERE so_id = p_so_id;
END;
$$;


ALTER PROCEDURE public.create_shipment(IN p_so_id integer, IN p_carrier_id integer, IN p_warehouse_id integer, IN p_shipping_date date, IN p_tracking_number character varying, IN p_user_id integer) OWNER TO postgres;

--
-- Name: getproducttotalinventory(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.getproducttotalinventory(p_product_id integer) RETURNS numeric
    LANGUAGE sql
    AS $$
    SELECT COALESCE(SUM(quantity), 0)
    FROM Current_Inventory ci
    JOIN Warehouse_Locations wl ON ci.location_id = wl.location_id
    JOIN Warehouses w ON wl.warehouse_id = w.warehouse_id
    WHERE ci.product_id = p_product_id
      AND w.is_deleted = FALSE; -- Враховуємо лише активні склади
$$;


ALTER FUNCTION public.getproducttotalinventory(p_product_id integer) OWNER TO postgres;

--
-- Name: isuseractive(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.isuseractive(p_user_id integer) RETURNS boolean
    LANGUAGE sql
    AS $$
    SELECT NOT is_deleted
    FROM Users
    WHERE user_id = p_user_id;
$$;


ALTER FUNCTION public.isuseractive(p_user_id integer) OWNER TO postgres;

--
-- Name: log_audit_changes(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_audit_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_changed_by integer := NULL;
  v_new_json jsonb;
  v_old_json jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_new_json := to_jsonb(NEW);
    IF (v_new_json ? 'updated_by') THEN
      v_changed_by := (v_new_json ->> 'updated_by')::integer;
    END IF;
    INSERT INTO audit_logs(table_name, record_id, operation, changed_by, diff)
      VALUES (TG_TABLE_NAME, to_jsonb(NEW)::text, 'INSERT', v_changed_by, v_new_json);
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    v_new_json := to_jsonb(NEW);
    v_old_json := to_jsonb(OLD);
    IF (v_new_json ? 'updated_by') THEN
      v_changed_by := (v_new_json ->> 'updated_by')::integer;
    END IF;
    INSERT INTO audit_logs(table_name, record_id, operation, changed_by, diff)
      VALUES (TG_TABLE_NAME, to_jsonb(NEW)::text, 'UPDATE', v_changed_by, jsonb_build_object('old', v_old_json, 'new', v_new_json));
    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN
    v_old_json := to_jsonb(OLD);
    IF (v_old_json ? 'updated_by') THEN
      v_changed_by := (v_old_json ->> 'updated_by')::integer;
    END IF;
    INSERT INTO audit_logs(table_name, record_id, operation, changed_by, diff)
      VALUES (TG_TABLE_NAME, to_jsonb(OLD)::text, 'DELETE', v_changed_by, v_old_json);
    RETURN OLD;
  END IF;
END;
$$;


ALTER FUNCTION public.log_audit_changes() OWNER TO postgres;

--
-- Name: restoreproduct(integer, integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.restoreproduct(IN p_product_id integer, IN p_user_id integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE Products
    SET 
        is_deleted = FALSE,
        updated_by = p_user_id,
        updated_at = NOW()
    WHERE product_id = p_product_id
      AND is_deleted = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Товар з ID % не знайдено або він є активним.', p_product_id;
    END IF;
END;
$$;


ALTER PROCEDURE public.restoreproduct(IN p_product_id integer, IN p_user_id integer) OWNER TO postgres;

--
-- Name: restoresupplier(integer, integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.restoresupplier(IN p_supplier_id integer, IN p_user_id integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE suppliers
  SET is_deleted = FALSE
  WHERE supplier_id = p_supplier_id AND is_deleted = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Supplier with ID % not found or not deleted', p_supplier_id;
  END IF;
END;
$$;


ALTER PROCEDURE public.restoresupplier(IN p_supplier_id integer, IN p_user_id integer) OWNER TO postgres;

--
-- Name: softdeletecustomer(integer, integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.softdeletecustomer(IN p_customer_id integer, IN p_user_id integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE customers
  SET is_deleted = TRUE
  WHERE customer_id = p_customer_id AND is_deleted = FALSE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Customer with ID % not found', p_customer_id;
  END IF;
END;
$$;


ALTER PROCEDURE public.softdeletecustomer(IN p_customer_id integer, IN p_user_id integer) OWNER TO postgres;

--
-- Name: softdeleteproduct(integer, integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.softdeleteproduct(IN p_product_id integer, IN p_user_id integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE Products
    SET 
        is_deleted = TRUE,
        updated_by = p_user_id,
        updated_at = NOW() -- Тригер set_timestamp також спрацює, але краще прописати
    WHERE product_id = p_product_id
      AND is_deleted = FALSE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Товар з ID % не знайдено або він вже видалений.', p_product_id;
    END IF;
END;
$$;


ALTER PROCEDURE public.softdeleteproduct(IN p_product_id integer, IN p_user_id integer) OWNER TO postgres;

--
-- Name: softdeletesalesorder(integer, integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.softdeletesalesorder(IN p_so_id integer, IN p_user_id integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE sales_orders
  SET
    status = 'Deleted',
    updated_by = p_user_id,
    updated_at = NOW()
  WHERE so_id = p_so_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sales order with ID % not found', p_so_id;
  END IF;
END;
$$;


ALTER PROCEDURE public.softdeletesalesorder(IN p_so_id integer, IN p_user_id integer) OWNER TO postgres;

--
-- Name: softdeletesupplier(integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.softdeletesupplier(IN p_supplier_id integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE Suppliers
    SET 
        is_deleted = TRUE
    WHERE supplier_id = p_supplier_id
      AND is_deleted = FALSE;
      
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Постачальника з ID % не знайдено або він вже видалений.', p_supplier_id;
    END IF;
END;
$$;


ALTER PROCEDURE public.softdeletesupplier(IN p_supplier_id integer) OWNER TO postgres;

--
-- Name: update_timestamp(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
   NEW.updated_at = NOW();
   RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_timestamp() OWNER TO postgres;

--
-- Name: updateinventoryongoodsreceipt_simplified(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.updateinventoryongoodsreceipt_simplified() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_location_id INTEGER;
    r_item RECORD;
BEGIN
    -- 1. Знаходимо "DEFAULT" локацію для складу, зазначеного в новому записі Goods_Receipts
    SELECT location_id INTO v_location_id 
    FROM Warehouse_Locations
    WHERE warehouse_id = NEW.warehouse_id AND location_code = 'DEFAULT';

    IF v_location_id IS NULL THEN
        RAISE EXCEPTION 'Не знайдено локацію "DEFAULT" для складу ID: %', NEW.warehouse_id;
    END IF;

    -- 2. Перебираємо всі позиції (PO_Items) пов'язаного Замовлення на Закупівлю (NEW.po_id)
    FOR r_item IN (
        SELECT product_id, ordered_quantity 
        FROM PO_Items 
        WHERE po_id = NEW.po_id
    )
    LOOP
        -- 3. Оновлюємо або вставляємо запис у Current_Inventory
        INSERT INTO Current_Inventory (product_id, location_id, quantity)
        VALUES (r_item.product_id, v_location_id, r_item.ordered_quantity)
        ON CONFLICT (product_id, location_id) DO UPDATE
        SET quantity = Current_Inventory.quantity + EXCLUDED.quantity;

        -- 4. Записуємо в Inventory_History
        INSERT INTO Inventory_History (product_id, location_id_to, quantity_change, operation_type, related_document_id, movement_date)
        VALUES (r_item.product_id, v_location_id, r_item.ordered_quantity, 'GR', NEW.gr_id, NEW.receipt_date);
    END LOOP;
    
    -- 5. Оновлюємо статус PO на 'Виконано' (логічне завершення процесу)
    UPDATE Purchase_Orders
    SET status = 'Виконано'
    WHERE po_id = NEW.po_id;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.updateinventoryongoodsreceipt_simplified() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.audit_logs (
    audit_id bigint NOT NULL,
    table_name text NOT NULL,
    record_id text,
    operation text NOT NULL,
    changed_by integer,
    changed_at timestamp with time zone DEFAULT now(),
    diff jsonb
);


ALTER TABLE public.audit_logs OWNER TO postgres;

--
-- Name: audit_logs_audit_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.audit_logs_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.audit_logs_audit_id_seq OWNER TO postgres;

--
-- Name: audit_logs_audit_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.audit_logs_audit_id_seq OWNED BY public.audit_logs.audit_id;


--
-- Name: carriers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.carriers (
    carrier_id integer NOT NULL,
    name character varying(150) NOT NULL,
    service_contact character varying(100)
);


ALTER TABLE public.carriers OWNER TO postgres;

--
-- Name: carriers_carrier_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.carriers_carrier_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.carriers_carrier_id_seq OWNER TO postgres;

--
-- Name: carriers_carrier_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.carriers_carrier_id_seq OWNED BY public.carriers.carrier_id;


--
-- Name: current_inventory; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.current_inventory (
    inventory_id integer NOT NULL,
    product_id integer NOT NULL,
    location_id integer NOT NULL,
    quantity numeric(18,4) NOT NULL,
    CONSTRAINT current_inventory_quantity_check CHECK ((quantity >= (0)::numeric))
);


ALTER TABLE public.current_inventory OWNER TO postgres;

--
-- Name: current_inventory_inventory_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.current_inventory_inventory_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.current_inventory_inventory_id_seq OWNER TO postgres;

--
-- Name: current_inventory_inventory_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.current_inventory_inventory_id_seq OWNED BY public.current_inventory.inventory_id;


--
-- Name: customers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.customers (
    customer_id integer NOT NULL,
    name character varying(255) NOT NULL,
    address text,
    phone character varying(20),
    email character varying(100),
    is_deleted boolean DEFAULT false NOT NULL
);


ALTER TABLE public.customers OWNER TO postgres;

--
-- Name: customers_customer_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.customers_customer_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customers_customer_id_seq OWNER TO postgres;

--
-- Name: customers_customer_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.customers_customer_id_seq OWNED BY public.customers.customer_id;


--
-- Name: goods_receipts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.goods_receipts (
    gr_id integer NOT NULL,
    po_id integer NOT NULL,
    warehouse_id integer NOT NULL,
    receipt_date date NOT NULL,
    status character varying(50) NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    updated_by integer
);


ALTER TABLE public.goods_receipts OWNER TO postgres;

--
-- Name: goods_receipts_gr_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.goods_receipts_gr_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.goods_receipts_gr_id_seq OWNER TO postgres;

--
-- Name: goods_receipts_gr_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.goods_receipts_gr_id_seq OWNED BY public.goods_receipts.gr_id;


--
-- Name: inventory_history; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.inventory_history (
    history_id bigint NOT NULL,
    product_id integer NOT NULL,
    location_id_from integer,
    location_id_to integer,
    quantity_change numeric(18,4) NOT NULL,
    operation_type character varying(50) NOT NULL,
    related_document_id integer,
    movement_date timestamp with time zone DEFAULT now()
);


ALTER TABLE public.inventory_history OWNER TO postgres;

--
-- Name: inventory_history_history_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.inventory_history_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.inventory_history_history_id_seq OWNER TO postgres;

--
-- Name: inventory_history_history_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.inventory_history_history_id_seq OWNED BY public.inventory_history.history_id;


--
-- Name: po_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.po_items (
    po_item_id integer NOT NULL,
    po_id integer NOT NULL,
    product_id integer NOT NULL,
    ordered_quantity numeric(18,4) NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    received_quantity numeric(18,4) DEFAULT 0,
    CONSTRAINT po_items_ordered_quantity_check CHECK ((ordered_quantity > (0)::numeric)),
    CONSTRAINT po_items_received_quantity_check CHECK ((received_quantity >= (0)::numeric)),
    CONSTRAINT po_items_unit_price_check CHECK ((unit_price >= (0)::numeric))
);


ALTER TABLE public.po_items OWNER TO postgres;

--
-- Name: po_items_po_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.po_items_po_item_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.po_items_po_item_id_seq OWNER TO postgres;

--
-- Name: po_items_po_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.po_items_po_item_id_seq OWNED BY public.po_items.po_item_id;


--
-- Name: product_categories; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.product_categories (
    category_id integer NOT NULL,
    name character varying(100) NOT NULL
);


ALTER TABLE public.product_categories OWNER TO postgres;

--
-- Name: product_categories_category_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.product_categories_category_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.product_categories_category_id_seq OWNER TO postgres;

--
-- Name: product_categories_category_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.product_categories_category_id_seq OWNED BY public.product_categories.category_id;


--
-- Name: products; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.products (
    product_id integer NOT NULL,
    name character varying(255) NOT NULL,
    sku character varying(50) NOT NULL,
    category_id integer NOT NULL,
    base_uom_id integer NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    is_deleted boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    updated_by integer,
    CONSTRAINT products_unit_price_check CHECK ((unit_price >= (0)::numeric))
);


ALTER TABLE public.products OWNER TO postgres;

--
-- Name: products_product_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.products_product_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.products_product_id_seq OWNER TO postgres;

--
-- Name: products_product_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.products_product_id_seq OWNED BY public.products.product_id;


--
-- Name: purchase_orders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchase_orders (
    po_id integer NOT NULL,
    supplier_id integer NOT NULL,
    order_date date NOT NULL,
    status character varying(50) NOT NULL,
    total_amount numeric(15,2),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    updated_by integer,
    CONSTRAINT purchase_orders_total_amount_check CHECK ((total_amount >= (0)::numeric))
);


ALTER TABLE public.purchase_orders OWNER TO postgres;

--
-- Name: purchase_orders_po_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchase_orders_po_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchase_orders_po_id_seq OWNER TO postgres;

--
-- Name: purchase_orders_po_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchase_orders_po_id_seq OWNED BY public.purchase_orders.po_id;


--
-- Name: sales_orders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sales_orders (
    so_id integer NOT NULL,
    customer_id integer NOT NULL,
    order_date date NOT NULL,
    delivery_date date,
    status character varying(50) NOT NULL,
    total_amount numeric(15,2),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    updated_by integer,
    CONSTRAINT sales_orders_total_amount_check CHECK ((total_amount >= (0)::numeric))
);


ALTER TABLE public.sales_orders OWNER TO postgres;

--
-- Name: sales_orders_so_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.sales_orders_so_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.sales_orders_so_id_seq OWNER TO postgres;

--
-- Name: sales_orders_so_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.sales_orders_so_id_seq OWNED BY public.sales_orders.so_id;


--
-- Name: shipments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.shipments (
    shipment_id integer NOT NULL,
    so_id integer NOT NULL,
    carrier_id integer NOT NULL,
    warehouse_id integer NOT NULL,
    shipping_date date NOT NULL,
    tracking_number character varying(100),
    status character varying(50) NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    updated_by integer
);


ALTER TABLE public.shipments OWNER TO postgres;

--
-- Name: shipments_shipment_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.shipments_shipment_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.shipments_shipment_id_seq OWNER TO postgres;

--
-- Name: shipments_shipment_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.shipments_shipment_id_seq OWNED BY public.shipments.shipment_id;


--
-- Name: so_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.so_items (
    so_item_id integer NOT NULL,
    so_id integer NOT NULL,
    product_id integer NOT NULL,
    ordered_quantity numeric(18,4) NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    shipped_quantity numeric(18,4) DEFAULT 0,
    CONSTRAINT so_items_ordered_quantity_check CHECK ((ordered_quantity > (0)::numeric)),
    CONSTRAINT so_items_shipped_quantity_check CHECK ((shipped_quantity >= (0)::numeric)),
    CONSTRAINT so_items_unit_price_check CHECK ((unit_price >= (0)::numeric))
);


ALTER TABLE public.so_items OWNER TO postgres;

--
-- Name: so_items_so_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.so_items_so_item_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.so_items_so_item_id_seq OWNER TO postgres;

--
-- Name: so_items_so_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.so_items_so_item_id_seq OWNED BY public.so_items.so_item_id;


--
-- Name: suppliers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.suppliers (
    supplier_id integer NOT NULL,
    name character varying(255) NOT NULL,
    contact_person character varying(100),
    phone character varying(20),
    email character varying(100),
    is_deleted boolean DEFAULT false NOT NULL
);


ALTER TABLE public.suppliers OWNER TO postgres;

--
-- Name: suppliers_supplier_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.suppliers_supplier_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.suppliers_supplier_id_seq OWNER TO postgres;

--
-- Name: suppliers_supplier_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.suppliers_supplier_id_seq OWNED BY public.suppliers.supplier_id;


--
-- Name: units_of_measure; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.units_of_measure (
    uom_id integer NOT NULL,
    name character varying(50) NOT NULL,
    abbreviation character varying(10) NOT NULL
);


ALTER TABLE public.units_of_measure OWNER TO postgres;

--
-- Name: units_of_measure_uom_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.units_of_measure_uom_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.units_of_measure_uom_id_seq OWNER TO postgres;

--
-- Name: units_of_measure_uom_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.units_of_measure_uom_id_seq OWNED BY public.units_of_measure.uom_id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users (
    user_id integer NOT NULL,
    username character varying(50) NOT NULL,
    full_name character varying(100) NOT NULL,
    email character varying(100) NOT NULL,
    is_deleted boolean DEFAULT false NOT NULL
);


ALTER TABLE public.users OWNER TO postgres;

--
-- Name: users_user_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.users_user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.users_user_id_seq OWNER TO postgres;

--
-- Name: users_user_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.users_user_id_seq OWNED BY public.users.user_id;


--
-- Name: v_activeproducts; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_activeproducts AS
 SELECT p.product_id,
    p.name AS product_name,
    p.sku,
    p.unit_price,
    c.name AS category_name,
    uom.abbreviation AS uom
   FROM ((public.products p
     JOIN public.product_categories c ON ((p.category_id = c.category_id)))
     JOIN public.units_of_measure uom ON ((p.base_uom_id = uom.uom_id)))
  WHERE (p.is_deleted = false);


ALTER VIEW public.v_activeproducts OWNER TO postgres;

--
-- Name: v_product_inventory; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_product_inventory AS
 SELECT p.product_id,
    p.name,
    COALESCE(sum(ci.quantity), (0)::numeric) AS total_quantity
   FROM (public.products p
     LEFT JOIN public.current_inventory ci ON ((p.product_id = ci.product_id)))
  GROUP BY p.product_id, p.name;


ALTER VIEW public.v_product_inventory OWNER TO postgres;

--
-- Name: v_purchaseorderssummary; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_purchaseorderssummary AS
 SELECT p.po_id AS "PoId",
    s.name AS "SupplierName",
    p.order_date AS "OrderDate",
    p.status AS "Status",
    u.username AS "UpdatedByUser",
    p.updated_at AS "UpdatedAt"
   FROM ((public.purchase_orders p
     JOIN public.suppliers s ON ((s.supplier_id = p.supplier_id)))
     JOIN public.users u ON ((u.user_id = p.updated_by)));


ALTER VIEW public.v_purchaseorderssummary OWNER TO postgres;

--
-- Name: warehouse_locations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.warehouse_locations (
    location_id integer NOT NULL,
    warehouse_id integer NOT NULL,
    location_code character varying(50) NOT NULL,
    location_type character varying(50)
);


ALTER TABLE public.warehouse_locations OWNER TO postgres;

--
-- Name: warehouse_locations_location_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.warehouse_locations_location_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.warehouse_locations_location_id_seq OWNER TO postgres;

--
-- Name: warehouse_locations_location_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.warehouse_locations_location_id_seq OWNED BY public.warehouse_locations.location_id;


--
-- Name: warehouses; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.warehouses (
    warehouse_id integer NOT NULL,
    name character varying(100) NOT NULL,
    address text,
    is_deleted boolean DEFAULT false NOT NULL
);


ALTER TABLE public.warehouses OWNER TO postgres;

--
-- Name: warehouses_warehouse_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.warehouses_warehouse_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.warehouses_warehouse_id_seq OWNER TO postgres;

--
-- Name: warehouses_warehouse_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.warehouses_warehouse_id_seq OWNED BY public.warehouses.warehouse_id;


--
-- Name: audit_logs audit_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_logs ALTER COLUMN audit_id SET DEFAULT nextval('public.audit_logs_audit_id_seq'::regclass);


--
-- Name: carriers carrier_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.carriers ALTER COLUMN carrier_id SET DEFAULT nextval('public.carriers_carrier_id_seq'::regclass);


--
-- Name: current_inventory inventory_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.current_inventory ALTER COLUMN inventory_id SET DEFAULT nextval('public.current_inventory_inventory_id_seq'::regclass);


--
-- Name: customers customer_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers ALTER COLUMN customer_id SET DEFAULT nextval('public.customers_customer_id_seq'::regclass);


--
-- Name: goods_receipts gr_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.goods_receipts ALTER COLUMN gr_id SET DEFAULT nextval('public.goods_receipts_gr_id_seq'::regclass);


--
-- Name: inventory_history history_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inventory_history ALTER COLUMN history_id SET DEFAULT nextval('public.inventory_history_history_id_seq'::regclass);


--
-- Name: po_items po_item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.po_items ALTER COLUMN po_item_id SET DEFAULT nextval('public.po_items_po_item_id_seq'::regclass);


--
-- Name: product_categories category_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_categories ALTER COLUMN category_id SET DEFAULT nextval('public.product_categories_category_id_seq'::regclass);


--
-- Name: products product_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products ALTER COLUMN product_id SET DEFAULT nextval('public.products_product_id_seq'::regclass);


--
-- Name: purchase_orders po_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_orders ALTER COLUMN po_id SET DEFAULT nextval('public.purchase_orders_po_id_seq'::regclass);


--
-- Name: sales_orders so_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders ALTER COLUMN so_id SET DEFAULT nextval('public.sales_orders_so_id_seq'::regclass);


--
-- Name: shipments shipment_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.shipments ALTER COLUMN shipment_id SET DEFAULT nextval('public.shipments_shipment_id_seq'::regclass);


--
-- Name: so_items so_item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.so_items ALTER COLUMN so_item_id SET DEFAULT nextval('public.so_items_so_item_id_seq'::regclass);


--
-- Name: suppliers supplier_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.suppliers ALTER COLUMN supplier_id SET DEFAULT nextval('public.suppliers_supplier_id_seq'::regclass);


--
-- Name: units_of_measure uom_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.units_of_measure ALTER COLUMN uom_id SET DEFAULT nextval('public.units_of_measure_uom_id_seq'::regclass);


--
-- Name: users user_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users ALTER COLUMN user_id SET DEFAULT nextval('public.users_user_id_seq'::regclass);


--
-- Name: warehouse_locations location_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse_locations ALTER COLUMN location_id SET DEFAULT nextval('public.warehouse_locations_location_id_seq'::regclass);


--
-- Name: warehouses warehouse_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouses ALTER COLUMN warehouse_id SET DEFAULT nextval('public.warehouses_warehouse_id_seq'::regclass);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (audit_id);


--
-- Name: carriers carriers_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.carriers
    ADD CONSTRAINT carriers_name_key UNIQUE (name);


--
-- Name: carriers carriers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.carriers
    ADD CONSTRAINT carriers_pkey PRIMARY KEY (carrier_id);


--
-- Name: current_inventory current_inventory_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.current_inventory
    ADD CONSTRAINT current_inventory_pkey PRIMARY KEY (inventory_id);


--
-- Name: current_inventory current_inventory_product_id_location_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.current_inventory
    ADD CONSTRAINT current_inventory_product_id_location_id_key UNIQUE (product_id, location_id);


--
-- Name: customers customers_name_is_deleted_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_name_is_deleted_key UNIQUE (name, is_deleted);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (customer_id);


--
-- Name: goods_receipts goods_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.goods_receipts
    ADD CONSTRAINT goods_receipts_pkey PRIMARY KEY (gr_id);


--
-- Name: inventory_history inventory_history_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inventory_history
    ADD CONSTRAINT inventory_history_pkey PRIMARY KEY (history_id);


--
-- Name: po_items po_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.po_items
    ADD CONSTRAINT po_items_pkey PRIMARY KEY (po_item_id);


--
-- Name: product_categories product_categories_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_categories
    ADD CONSTRAINT product_categories_name_key UNIQUE (name);


--
-- Name: product_categories product_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_categories
    ADD CONSTRAINT product_categories_pkey PRIMARY KEY (category_id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (product_id);


--
-- Name: products products_sku_is_deleted_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_sku_is_deleted_key UNIQUE (sku, is_deleted);


--
-- Name: products products_sku_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_sku_key UNIQUE (sku);


--
-- Name: purchase_orders purchase_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_pkey PRIMARY KEY (po_id);


--
-- Name: sales_orders sales_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_pkey PRIMARY KEY (so_id);


--
-- Name: shipments shipments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.shipments
    ADD CONSTRAINT shipments_pkey PRIMARY KEY (shipment_id);


--
-- Name: so_items so_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.so_items
    ADD CONSTRAINT so_items_pkey PRIMARY KEY (so_item_id);


--
-- Name: suppliers suppliers_name_is_deleted_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_name_is_deleted_key UNIQUE (name, is_deleted);


--
-- Name: suppliers suppliers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_pkey PRIMARY KEY (supplier_id);


--
-- Name: units_of_measure units_of_measure_abbreviation_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.units_of_measure
    ADD CONSTRAINT units_of_measure_abbreviation_key UNIQUE (abbreviation);


--
-- Name: units_of_measure units_of_measure_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.units_of_measure
    ADD CONSTRAINT units_of_measure_name_key UNIQUE (name);


--
-- Name: units_of_measure units_of_measure_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.units_of_measure
    ADD CONSTRAINT units_of_measure_pkey PRIMARY KEY (uom_id);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (user_id);


--
-- Name: users users_username_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_username_key UNIQUE (username);


--
-- Name: warehouse_locations warehouse_locations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse_locations
    ADD CONSTRAINT warehouse_locations_pkey PRIMARY KEY (location_id);


--
-- Name: warehouse_locations warehouse_locations_warehouse_id_location_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse_locations
    ADD CONSTRAINT warehouse_locations_warehouse_id_location_code_key UNIQUE (warehouse_id, location_code);


--
-- Name: warehouses warehouses_name_is_deleted_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT warehouses_name_is_deleted_key UNIQUE (name, is_deleted);


--
-- Name: warehouses warehouses_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT warehouses_name_key UNIQUE (name);


--
-- Name: warehouses warehouses_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT warehouses_pkey PRIMARY KEY (warehouse_id);


--
-- Name: idx_audit_logs_table_time; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_logs_table_time ON public.audit_logs USING btree (table_name, changed_at);


--
-- Name: idx_inventory_history_movement_date_brin; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_inventory_history_movement_date_brin ON public.inventory_history USING brin (movement_date);


--
-- Name: idx_po_pending_date; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_po_pending_date ON public.purchase_orders USING btree (order_date) WHERE ((status)::text <> 'Виконано'::text);


--
-- Name: idx_po_supplier_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_po_supplier_id ON public.purchase_orders USING btree (supplier_id);


--
-- Name: idx_products_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_products_active ON public.products USING btree ((
CASE
    WHEN (is_deleted = false) THEN 1
    ELSE NULL::integer
END), sku);


--
-- Name: idx_products_name_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_products_name_trgm ON public.products USING gin (name public.gin_trgm_ops);


--
-- Name: idx_products_sku; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_products_sku ON public.products USING btree (sku);


--
-- Name: idx_suppliers_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_suppliers_active ON public.suppliers USING btree ((
CASE
    WHEN (is_deleted = false) THEN 1
    ELSE NULL::integer
END), name);


--
-- Name: goods_receipts aftergoodsreceiptinsert_simplified; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER aftergoodsreceiptinsert_simplified AFTER INSERT ON public.goods_receipts FOR EACH ROW EXECUTE FUNCTION public.updateinventoryongoodsreceipt_simplified();


--
-- Name: purchase_orders beforepoupdate; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER beforepoupdate BEFORE INSERT OR UPDATE ON public.purchase_orders FOR EACH ROW EXECUTE FUNCTION public.checkuseractivitybeforeupdate();


--
-- Name: goods_receipts trg_goods_receipts_audit; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_goods_receipts_audit AFTER INSERT OR DELETE OR UPDATE ON public.goods_receipts FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();


--
-- Name: goods_receipts trg_goods_receipts_update_timestamp; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_goods_receipts_update_timestamp BEFORE UPDATE ON public.goods_receipts FOR EACH ROW EXECUTE FUNCTION public.update_timestamp();


--
-- Name: products trg_products_audit; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_products_audit AFTER INSERT OR DELETE OR UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();


--
-- Name: products trg_products_update_timestamp; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_products_update_timestamp BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.update_timestamp();


--
-- Name: purchase_orders trg_purchase_orders_audit; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_purchase_orders_audit AFTER INSERT OR DELETE OR UPDATE ON public.purchase_orders FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();


--
-- Name: purchase_orders trg_purchase_orders_update_timestamp; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_purchase_orders_update_timestamp BEFORE UPDATE ON public.purchase_orders FOR EACH ROW EXECUTE FUNCTION public.update_timestamp();


--
-- Name: sales_orders trg_sales_orders_audit; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sales_orders_audit AFTER INSERT OR DELETE OR UPDATE ON public.sales_orders FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();


--
-- Name: sales_orders trg_sales_orders_update_timestamp; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sales_orders_update_timestamp BEFORE UPDATE ON public.sales_orders FOR EACH ROW EXECUTE FUNCTION public.update_timestamp();


--
-- Name: shipments trg_shipments_audit; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_shipments_audit AFTER INSERT OR DELETE OR UPDATE ON public.shipments FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();


--
-- Name: shipments trg_shipments_update_timestamp; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_shipments_update_timestamp BEFORE UPDATE ON public.shipments FOR EACH ROW EXECUTE FUNCTION public.update_timestamp();


--
-- Name: current_inventory current_inventory_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.current_inventory
    ADD CONSTRAINT current_inventory_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.warehouse_locations(location_id);


--
-- Name: current_inventory current_inventory_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.current_inventory
    ADD CONSTRAINT current_inventory_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: goods_receipts goods_receipts_po_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.goods_receipts
    ADD CONSTRAINT goods_receipts_po_id_fkey FOREIGN KEY (po_id) REFERENCES public.purchase_orders(po_id);


--
-- Name: goods_receipts goods_receipts_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.goods_receipts
    ADD CONSTRAINT goods_receipts_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- Name: goods_receipts goods_receipts_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.goods_receipts
    ADD CONSTRAINT goods_receipts_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(warehouse_id);


--
-- Name: inventory_history inventory_history_location_id_from_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inventory_history
    ADD CONSTRAINT inventory_history_location_id_from_fkey FOREIGN KEY (location_id_from) REFERENCES public.warehouse_locations(location_id);


--
-- Name: inventory_history inventory_history_location_id_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inventory_history
    ADD CONSTRAINT inventory_history_location_id_to_fkey FOREIGN KEY (location_id_to) REFERENCES public.warehouse_locations(location_id);


--
-- Name: inventory_history inventory_history_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inventory_history
    ADD CONSTRAINT inventory_history_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: po_items po_items_po_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.po_items
    ADD CONSTRAINT po_items_po_id_fkey FOREIGN KEY (po_id) REFERENCES public.purchase_orders(po_id) ON DELETE CASCADE;


--
-- Name: po_items po_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.po_items
    ADD CONSTRAINT po_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: products products_base_uom_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_base_uom_id_fkey FOREIGN KEY (base_uom_id) REFERENCES public.units_of_measure(uom_id);


--
-- Name: products products_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.product_categories(category_id);


--
-- Name: products products_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- Name: purchase_orders purchase_orders_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(supplier_id);


--
-- Name: purchase_orders purchase_orders_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- Name: sales_orders sales_orders_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- Name: sales_orders sales_orders_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- Name: shipments shipments_carrier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.shipments
    ADD CONSTRAINT shipments_carrier_id_fkey FOREIGN KEY (carrier_id) REFERENCES public.carriers(carrier_id);


--
-- Name: shipments shipments_so_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.shipments
    ADD CONSTRAINT shipments_so_id_fkey FOREIGN KEY (so_id) REFERENCES public.sales_orders(so_id);


--
-- Name: shipments shipments_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.shipments
    ADD CONSTRAINT shipments_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(user_id);


--
-- Name: shipments shipments_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.shipments
    ADD CONSTRAINT shipments_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(warehouse_id);


--
-- Name: so_items so_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.so_items
    ADD CONSTRAINT so_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: so_items so_items_so_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.so_items
    ADD CONSTRAINT so_items_so_id_fkey FOREIGN KEY (so_id) REFERENCES public.sales_orders(so_id) ON DELETE CASCADE;


--
-- Name: warehouse_locations warehouse_locations_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse_locations
    ADD CONSTRAINT warehouse_locations_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(warehouse_id);


--
-- PostgreSQL database dump complete
--

\unrestrict 6kEvsNQSM87bIbLSFt125AGTDAVheCxwk6iGUUhGZ8DO7Je22BOzHlq32RnNNce

