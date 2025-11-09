using System.Threading.Tasks;

namespace SupplyChainManagementDapper.Contracts
{
    public interface IShipmentRepository
    {
        Task CreateShipmentAsync(int soId, int carrierId, int warehouseId, DateTime shippingDate, string trackingNumber, int userId);
    }
}
