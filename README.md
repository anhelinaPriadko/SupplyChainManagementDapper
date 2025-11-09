# SupplyChainManagementDapper Lab

## Overview
This is a .NET 8 Web API project for managing products, purchase orders, and shipments using **Dapper** and **PostgreSQL**.  
The project supports:
- Listing active products
- Soft-deleting products
- Creating purchase orders
- Viewing pending purchase orders
- Creating shipments

## Project Structure
SupplyChainManagementDapper/
├─ Controllers/ # API controllers
├─ Contracts/ # Repository and UnitOfWork interfaces
├─ Data/ # Repository and UnitOfWork implementations
├─ Models/ # Entity classes
├─ Program.cs # App entry point
└─ appsettings.json # Configuration (update connection string)
schema.sql # PostgreSQL database dump
README.md # This file

## Setup

1. **Restore NuGet packages**  
   Open the project in Visual Studio and restore all packages (Dapper, Npgsql, etc.).

2. **Create the database**  
   - Open `schema.sql` in PostgreSQL (e.g., pgAdmin) and execute it to create tables, views, stored procedures, and initial data.

3. **Configure connection string**  
   - Open `appsettings.json` and update the `"PostgresConnection"` string with your database credentials:
   ```json
   "ConnectionStrings": {
       "PostgresConnection": "Host=localhost;Port=5432;Database=YourDB;Username=YourUser;Password=YourPassword"
   }
Run the project

Press F5 in Visual Studio or run via dotnet run.

Swagger UI will open at https://localhost:{PORT}/swagger for testing API endpoints.

API Endpoints
Products
GET /api/Product/active – List active products

DELETE /api/Product/soft-delete/{productId}?userId={userId} – Soft-delete a product

Purchase Orders
GET /api/PurchaseOrder/pending-summary – List pending purchase orders

POST /api/PurchaseOrder/create – Create a new purchase order
Example JSON:

{
  "supplierId": 1,
  "orderDate": "2025-11-09",
  "createdBy": 1,
  "items": [
    { "productId": 1, "orderedQuantity": 20, "unitPrice": 9.5 },
    { "productId": 2, "orderedQuantity": 10, "unitPrice": 24.0 }
  ]
}
Shipments
POST /api/Shipment/create – Create a new shipment
Example JSON:

{
  "soId": 1,
  "carrierId": 1,
  "warehouseId": 1,
  "shippingDate": "2025-11-09",
  "trackingNumber": "TR-001",
  "userId": 1
}
Notes
Make sure all referenced foreign keys exist (suppliers, carriers, warehouses, users) before creating orders or shipments.

Use Swagger UI to test API endpoints quickly.

The project uses soft delete for products; deleted products are not removed from the database, only marked as deleted.