using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Input;

namespace HerdrOps.App.Shell;

/// <summary>
/// Owns shell selection and keyboard routing without depending on live Herdr state.
/// </summary>
public sealed class ShellNavigationController : INotifyPropertyChanged
{
    private int selectedIndex;
    private bool isCompactSidebar;

    public event PropertyChangedEventHandler? PropertyChanged;

    public IReadOnlyList<ShellDestination> Destinations => ShellNavigationCatalog.All;

    public int SelectedIndex
    {
        get => selectedIndex;
        set
        {
            var boundedValue = Math.Clamp(value, 0, Destinations.Count - 1);
            if (selectedIndex == boundedValue)
            {
                return;
            }

            selectedIndex = boundedValue;
            OnPropertyChanged();
            OnPropertyChanged(nameof(SelectedDestination));
        }
    }

    public ShellDestination SelectedDestination => Destinations[SelectedIndex];

    public bool IsCompactSidebar
    {
        get => isCompactSidebar;
        set
        {
            if (isCompactSidebar == value)
            {
                return;
            }

            isCompactSidebar = value;
            OnPropertyChanged();
        }
    }

    public bool TryHandleKey(Key key, ModifierKeys modifiers)
    {
        if (modifiers == ModifierKeys.Control && key == Key.PageDown)
        {
            MoveSelection(1);
            return true;
        }

        if (modifiers == ModifierKeys.Control && key == Key.PageUp)
        {
            MoveSelection(-1);
            return true;
        }

        if (modifiers == ModifierKeys.Alt && key == Key.Home)
        {
            SelectedIndex = 0;
            return true;
        }

        if (modifiers == ModifierKeys.Alt && key == Key.End)
        {
            SelectedIndex = Destinations.Count - 1;
            return true;
        }

        return false;
    }

    public void MoveSelection(int offset)
    {
        var destinationCount = Destinations.Count;
        SelectedIndex = (SelectedIndex + offset + destinationCount) % destinationCount;
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
