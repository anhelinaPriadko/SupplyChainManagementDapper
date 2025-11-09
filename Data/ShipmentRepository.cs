using Dapper;
using Npgsql;
using SupplyChainManagementDapper.Contracts;
using System.Data;
using System.Threading.Tasks;

namespace SupplyChainManagementDapper.Data
{
    public class ShipmentRepository : IShipmentRepository
    {
        private readonly NpgsqlConnection _connection;
        private readonly IDbTransaction _transaction;

        public ShipmentRepository(NpgsqlConnection connection, IDbTransaction transaction)
        {
            _connection = connection;
            _transaction = transaction;
        }

        public async Task CreateShipmentAsync(int soId, int carrierId, int warehouseId, DateTime shippingDate, string trackingNumber, int userId)
        {
            var parameters = new
            {
                p_so_id = soId,
                p_carrier_id = carrierId,
                p_warehouse_id = warehouseId,
                p_shipping_date = shippingDate,   // DateTime в C#
                p_tracking_number = trackingNumber,
                p_user_id = userId
            };

            await _connection.ExecuteAsync(
                "CALL public.create_shipment(@p_so_id, @p_carrier_id, @p_warehouse_id, @p_shipping_date::date, @p_tracking_number, @p_user_id);",
                parameters,
                transaction: _transaction);
        }
    }
}
