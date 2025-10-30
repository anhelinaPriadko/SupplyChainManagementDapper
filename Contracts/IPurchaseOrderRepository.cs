using SupplyChainManagementDapper.Models;


namespace SupplyChainManagementDapper.Contracts
{
    public interface IPurchaseOrderRepository
    {
        Task<IEnumerable<PurchaseOrder>> GetPendingSummaryAsync();
    }
}
