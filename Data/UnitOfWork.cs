using Npgsql;
using SupplyChainManagementDapper.Contracts;
using System;
using System.Threading.Tasks;

namespace SupplyChainManagementDapper.Data
{
    public class UnitOfWork : IUnitOfWork, IAsyncDisposable
    {
        private readonly NpgsqlConnection _connection;
        private NpgsqlTransaction _transaction;
        private bool _disposed;
        private bool _completed;

        public IProductRepository Products { get; }
        public IPurchaseOrderRepository PurchaseOrders { get; }
        public IShipmentRepository Shipments { get; }

        public UnitOfWork(string connectionString)
        {
            _connection = new NpgsqlConnection(connectionString ?? throw new ArgumentNullException(nameof(connectionString)));
            _connection.Open();
            _transaction = _connection.BeginTransaction();

            Products = new ProductRepository(_connection, _transaction);
            PurchaseOrders = new PurchaseOrderRepository(_connection, _transaction);
            Shipments = new ShipmentRepository(_connection, _transaction);
        }

        public async Task CompleteAsync()
        {
            if (_disposed) throw new ObjectDisposedException(nameof(UnitOfWork));
            if (_completed) return;

            try
            {
                await _transaction.CommitAsync();
                _completed = true;
            }
            catch
            {
                try { await _transaction.RollbackAsync(); } catch { /* логування за потреби */ }
                throw;
            }
            finally
            {
                try { _transaction.Dispose(); } catch { }
                _transaction = null;
            }
        }

        public void Dispose()
        {
            // синхронний Dispose просто делегує асинхронному
            DisposeAsync().AsTask().GetAwaiter().GetResult();
        }

        public async ValueTask DisposeAsync()
        {
            if (_disposed) return;
            _disposed = true;

            // якщо транзакція не була підтверджена — робимо відкат
            if (!_completed && _transaction != null)
            {
                try
                {
                    await _transaction.RollbackAsync();
                }
                catch
                {
                    // не кидаємо виключення під час очищення
                    // можна залогувати помилку тут
                }
            }

            try { _transaction?.Dispose(); } catch { }
            _transaction = null;

            if (_connection != null)
            {
                try
                {
                    if (_connection.State != System.Data.ConnectionState.Closed)
                        _connection.Close();
                }
                catch { /* логування */ }

                try { _connection.Dispose(); } catch { }
            }
        }
    }
}
