using Dapper;
using Npgsql;
using SupplyChainManagementDapper.Contracts;
using SupplyChainManagementDapper.Models;

namespace SupplyChainManagementDapper.Data
{
    public class ProductRepository : IProductRepository
    {
        private readonly NpgsqlConnection _connection;

        public ProductRepository(NpgsqlConnection connection)
        {
            _connection = connection;
        }

        public async Task<IEnumerable<Product>> GetActiveAsync()
        {
            var sql = "SELECT * FROM V_ActiveProducts;";
            return await _connection.QueryAsync<Product>(sql);
        }

        public async Task SoftDeleteAsync(int productId, int userId)
        {
            var parameters = new { p_product_id = productId, p_user_id = userId };
            await _connection.ExecuteAsync("CALL SoftDeleteProduct(@p_product_id, @p_user_id)", parameters);
        }
    }
}
