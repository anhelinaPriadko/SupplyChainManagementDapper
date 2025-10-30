using Microsoft.AspNetCore.Mvc;
using SupplyChainManagementDapper.Contracts;
using SupplyChainManagementDapper.Models;

namespace SupplyChainManagementDapper.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class ProductController : ControllerBase
    {
        private readonly IUnitOfWork _unitOfWork;

        public ProductController(IUnitOfWork unitOfWork)
        {
            _unitOfWork = unitOfWork;
        }

        // GET: api/Product/active
        // Використовує VIEW V_ActiveProducts
        [HttpGet("active")]
        public async Task<ActionResult<IEnumerable<Product>>> GetActiveProducts()
        {
            var products = await _unitOfWork.Products.GetActiveAsync();
            return Ok(products);
        }

        // DELETE: api/Product/soft-delete/{id}
        // Використовує збережену процедуру SoftDeleteProduct
        [HttpDelete("soft-delete/{productId}")]
        public async Task<IActionResult> SoftDeleteProduct(int productId, [FromQuery] int userId)
        {
            if (userId <= 0)
            {
                return BadRequest("Потрібен дійсний userId для аудиту.");
            }

            try
            {
                await _unitOfWork.Products.SoftDeleteAsync(productId, userId);
                _unitOfWork.Complete();

                return NoContent();
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "P0001")
            {
                return BadRequest(new { message = $"Помилка БД: {ex.Detail}" });
            }
            catch (Exception)
            {
                return StatusCode(500, "Внутрішня помилка сервера під час операції.");
            }
        }
    }
}
