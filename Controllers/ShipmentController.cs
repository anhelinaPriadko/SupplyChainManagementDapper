using Microsoft.AspNetCore.Mvc;
using SupplyChainManagementDapper.Contracts;

namespace SupplyChainManagementDapper.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class ShipmentController : ControllerBase
    {
        private readonly IUnitOfWork _uow;

        public ShipmentController(IUnitOfWork uow)
        {
            _uow = uow;
        }

        // POST api/Shipment/create
        // Тіло JSON: { "soId":1, "carrierId":1, "warehouseId":1, "shippingDate":"2025-11-09", "trackingNumber":"TR123", "userId":1 }
        [HttpPost("create")]
        public async Task<IActionResult> CreateShipment([FromBody] ShipmentCreateDto dto)
        {
            try
            {
                await _uow.Shipments.CreateShipmentAsync(dto.SoId, dto.CarrierId, dto.WarehouseId, dto.ShippingDate, dto.TrackingNumber, dto.UserId);
                await _uow.CompleteAsync();
                return Ok(new { message = "Shipment created" });
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

    public class ShipmentCreateDto
    {
        public int SoId { get; set; }
        public int CarrierId { get; set; }
        public int WarehouseId { get; set; }
        public DateTime ShippingDate { get; set; }
        public string TrackingNumber { get; set; } = string.Empty;
        public int UserId { get; set; }
    }
}
