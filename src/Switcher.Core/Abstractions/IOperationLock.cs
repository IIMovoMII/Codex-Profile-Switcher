namespace Switcher.Core.Abstractions;

public interface IOperationLock : IAsyncDisposable
{
    ValueTask<IAsyncDisposable> AcquireAsync(string name, CancellationToken cancellationToken);
}
