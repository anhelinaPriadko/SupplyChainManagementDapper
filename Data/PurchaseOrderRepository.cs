using Dapper;
using Npgsql;
using SupplyChainManagementDapper.Contracts;
using SupplyChainManagementDapper.Models;

namespace SupplyChainManagementDapper.Data
{
    public class PurchaseOrderRepository : IPurchaseOrderRepository
    {
        private readonly NpgsqlConnection _connection;

        public PurchaseOrderRepository(NpgsqlConnection connection)
        {
            _connection = connection;
        }

        public async Task<IEnumerable<PurchaseOrder>> GetPendingSummaryAsync()
        {
            var sql = "SELECT * FROM V_PurchaseOrdersSummary;";
            return await _connection.QueryAsync<PurchaseOrder>(sql);
        }
    }
}
