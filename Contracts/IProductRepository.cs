using SupplyChainManagementDapper.Models;

namespace SupplyChainManagementDapper.Contracts
{
    public interface IProductRepository
    {
        Task<IEnumerable<Product>> GetActiveAsync();
        Task SoftDeleteAsync(int productId, int userId);
    }
}
