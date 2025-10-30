namespace SupplyChainManagementDapper.Models
{
    public class Product
    {
        public int ProductId { get; set; }
        public string ProductName { get; set; }
        public string Sku { get; set; }
        public decimal UnitPrice { get; set; }
        public string CategoryName { get; set; }
        public string Uom { get; set; }
    }
}
