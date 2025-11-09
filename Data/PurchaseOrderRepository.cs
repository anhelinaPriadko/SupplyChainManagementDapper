using Dapper;
using Npgsql;
using SupplyChainManagementDapper.Contracts;
using SupplyChainManagementDapper.Models;
using System.Data;
using System.Text.Json;

namespace SupplyChainManagementDapper.Data
{
    public class PurchaseOrderRepository : IPurchaseOrderRepository
    {
        private readonly NpgsqlConnection _connection;
        private readonly IDbTransaction _transaction;

        public PurchaseOrderRepository(NpgsqlConnection connection, IDbTransaction transaction)
        {
            _connection = connection;
            _transaction = transaction;
        }

        public async Task<IEnumerable<PurchaseOrder>> GetPendingSummaryAsync()
        {
            var sql = "SELECT * FROM v_purchaseorderssummary;";
            return await _connection.QueryAsync<PurchaseOrder>(sql, transaction: _transaction);
        }

        public async Task CreateAsync(int supplierId, DateTime orderDate, int createdBy, string itemsJson)
        {
            var parameters = new
            {
                p_supplier_id = supplierId,
                p_order_date = orderDate,
                p_created_by = createdBy,
                p_items = itemsJson
            };

            await _connection.ExecuteAsync(
                "CALL public.create_purchase_order(@p_supplier_id, @p_order_date::date, @p_created_by, @p_items::jsonb);",
                parameters,
                transaction: _transaction);
        }
    }
}
