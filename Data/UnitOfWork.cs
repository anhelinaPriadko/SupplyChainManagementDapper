using Npgsql;
using SupplyChainManagementDapper.Contracts;

namespace SupplyChainManagementDapper.Data
{
    public class UnitOfWork : IUnitOfWork
    {
        private readonly NpgsqlConnection _connection;
        private NpgsqlTransaction _transaction;

        public IProductRepository Products { get; }
        public IPurchaseOrderRepository PurchaseOrders { get; }

        public UnitOfWork(string connectionString)
        {
            _connection = new NpgsqlConnection(connectionString);
            _connection.Open();

            _transaction = _connection.BeginTransaction();

            Products = new ProductRepository(_connection);
            PurchaseOrders = new PurchaseOrderRepository(_connection);
        }

        public void Complete()
        {
            try
            {
                _transaction.Commit();
            }
            catch
            {
                _transaction.Rollback();
                throw;
            }
        }

        public void Dispose()
        {
            _transaction?.Dispose();
            if (_connection.State == System.Data.ConnectionState.Open)
            {
                _connection.Close();
            }
            _connection.Dispose();
        }
    }
}
