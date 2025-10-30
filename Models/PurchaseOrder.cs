namespace SupplyChainManagementDapper.Models
{
    public class PurchaseOrder
    {
        public int PoId { get; set; }
        public string SupplierName { get; set; }
        public DateTime OrderDate { get; set; }
        public string Status { get; set; }
        public string UpdatedByUser { get; set; }
        public DateTime UpdatedAt { get; set; }
    }
}
