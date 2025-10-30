using SupplyChainManagementDapper.Contracts;
using SupplyChainManagementDapper.Data;
using SupplyChainManagementDapper.Contracts;
using SupplyChainManagementDapper.Data;

var builder = WebApplication.CreateBuilder(args);
var connectionString = builder.Configuration.GetConnectionString("PostgresConnection");

builder.Services.AddTransient<IUnitOfWork>(sp => new UnitOfWork(connectionString));

builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var app = builder.Build();
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();
app.UseAuthorization();
app.MapControllers();
app.Run();