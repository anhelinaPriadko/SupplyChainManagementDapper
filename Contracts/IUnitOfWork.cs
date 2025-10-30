namespace SupplyChainManagementDapper.Contracts
{
    public interface IUnitOfWork: IDisposable
    {
        IProductRepository Products { get; }
        IPurchaseOrderRepository PurchaseOrders { get; }

        void Complete();
    }
}
