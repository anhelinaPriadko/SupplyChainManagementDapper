using Microsoft.AspNetCore.Mvc;
using SupplyChainManagementDapper.Contracts;
using System.Text.Json;

namespace SupplyChainManagementDapper.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class PurchaseOrderController : ControllerBase
    {
        private readonly IUnitOfWork _uow;

        public PurchaseOrderController(IUnitOfWork uow)
        {
            _uow = uow;
        }

        [HttpGet("pending-summary")]
        public async Task<IActionResult> GetPendingSummary()
        {
            var result = await _uow.PurchaseOrders.GetPendingSummaryAsync();
            return Ok(result);
        }

        [HttpPost("create")]
        public async Task<IActionResult> CreatePurchaseOrder([FromBody] PurchaseOrderCreateDto dto)
        {
            try
            {
                // серіалізуємо items у JSON рядок
                string itemsJson = JsonSerializer.Serialize(dto.Items);
                await _uow.PurchaseOrders.CreateAsync(dto.SupplierId, dto.OrderDate, dto.CreatedBy, itemsJson);
                await _uow.CompleteAsync();
                return Ok(new { message = "Purchase order created" });
            }
            catch (Npgsql.PostgresException ex)
            {
                return BadRequest(new { message = ex.MessageText, detail = ex.Detail });
            }
            catch (Exception)
            {
                return StatusCode(500, "Internal error");
            }
        }
    }

    public class PurchaseOrderCreateDto
    {
        public int SupplierId { get; set; }
        public DateTime OrderDate { get; set; }
        public int CreatedBy { get; set; }
        public List<PoItemDto> Items { get; set; } = new();

        public class PoItemDto
        {
            public int ProductId { get; set; }
            public decimal OrderedQuantity { get; set; }
            public decimal UnitPrice { get; set; }
        }
    }
}
