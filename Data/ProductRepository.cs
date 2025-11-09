using Dapper;
using Npgsql;
using SupplyChainManagementDapper.Contracts;
using SupplyChainManagementDapper.Models;
using System.Data;

namespace SupplyChainManagementDapper.Data
{
    public class ProductRepository : IProductRepository
    {
        private readonly NpgsqlConnection _connection;
        private readonly IDbTransaction _transaction;

        public ProductRepository(NpgsqlConnection connection, IDbTransaction transaction)
        {
            _connection = connection;
            _transaction = transaction;
        }

        public async Task<IEnumerable<Product>> GetActiveAsync()
        {
            var sql = @"
                SELECT
                    product_id   AS ""ProductId"",
                    product_name AS ""ProductName"",
                    sku          AS ""Sku"",
                    unit_price   AS ""UnitPrice"",
                    category_name AS ""CategoryName"",
                    uom          AS ""Uom""
                FROM v_activeproducts;
            ";
            return await _connection.QueryAsync<Product>(sql, transaction: _transaction);
        }

        public async Task SoftDeleteAsync(int productId, int userId)
        {
            var parameters = new { p_product_id = productId, p_user_id = userId };
            await _connection.ExecuteAsync("CALL public.softdeleteproduct(@p_product_id, @p_user_id);", parameters, transaction: _transaction);
        }
    }
}
