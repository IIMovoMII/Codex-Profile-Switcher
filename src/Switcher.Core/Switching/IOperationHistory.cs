namespace Switcher.Core.Switching;

public interface IOperationHistory
{
    IReadOnlyList<string> ReadRecent(int count = 200);
    void Append(string message);
}
