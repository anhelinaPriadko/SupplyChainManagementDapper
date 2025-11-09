using SupplyChainManagementDapper.Models;

namespace SupplyChainManagementDapper.Contracts
{
    public interface IPurchaseOrderRepository
    {
        Task<IEnumerable<PurchaseOrder>> GetPendingSummaryAsync();
        Task CreateAsync(int supplierId, DateTime orderDate, int createdBy, string itemsJson);
    }
}
