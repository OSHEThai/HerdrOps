using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;

namespace HerdrOps.App.Converters;

/// <summary>
/// Resolves a semantic resource key supplied by deterministic presentation state.
/// </summary>
public sealed class ResourceKeyToBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is string resourceKey &&
            Application.Current?.TryFindResource(resourceKey) is Brush brush)
        {
            return brush;
        }

        return Brushes.Transparent;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        throw new NotSupportedException();
    }
}
