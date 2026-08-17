namespace HerdrOps.App.Lifecycle;

/// <summary>
/// Stable geometry and pixel rules for the notification-area icon derived from
/// the approved HerdrOps mark. The source reference remains immutable; the
/// runtime adapter removes its dark screenshot matte before creating the icon.
/// </summary>
public static class TrayIconContract
{
    public const int ReferenceCanvasWidth = 1672;
    public const int ReferenceCanvasHeight = 941;
    public const int ReferenceCropLeft = 16;
    public const int ReferenceCropTop = 8;
    public const int ReferenceCropSize = 48;
    public const int LogicalPixelSize = 16;
    public const int MinimumPixelSize = 16;
    public const int MaximumPixelSize = 64;
    public const byte BackgroundCutoff = 40;

    public static int PixelSizeForDpi(double dpiScale)
    {
        if (double.IsNaN(dpiScale) || double.IsInfinity(dpiScale) || dpiScale <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(dpiScale));
        }

        var pixelSize = (int)Math.Round(
            LogicalPixelSize * dpiScale,
            MidpointRounding.AwayFromZero);
        return Math.Clamp(pixelSize, MinimumPixelSize, MaximumPixelSize);
    }

    public static byte AlphaForMattePixel(byte red, byte green, byte blue, byte sourceAlpha = 255)
    {
        if (sourceAlpha == 0)
        {
            return 0;
        }

        var intensity = Math.Max(red, Math.Max(green, blue));
        if (intensity <= BackgroundCutoff)
        {
            return 0;
        }

        var alpha = Math.Min(255, (intensity - BackgroundCutoff) * 4);
        return (byte)(alpha * sourceAlpha / 255);
    }

    /// <summary>
    /// Converts a Bgra32 screenshot crop into premultiplied Bgra32 with the
    /// dark screenshot matte removed. This is deliberately pure for synthetic
    /// alpha and bounds tests.
    /// </summary>
    public static byte[] ToTransparentPbgra32(ReadOnlySpan<byte> bgra32, int width, int height)
    {
        if (width <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(width));
        }

        if (height <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(height));
        }

        var expectedLength = checked(width * height * 4);
        if (bgra32.Length != expectedLength)
        {
            throw new ArgumentException("The Bgra32 buffer does not match the requested dimensions.", nameof(bgra32));
        }

        var output = new byte[expectedLength];
        for (var offset = 0; offset < bgra32.Length; offset += 4)
        {
            var blue = bgra32[offset];
            var green = bgra32[offset + 1];
            var red = bgra32[offset + 2];
            var alpha = AlphaForMattePixel(red, green, blue, bgra32[offset + 3]);
            output[offset + 3] = alpha;
            output[offset] = Premultiply(blue, alpha);
            output[offset + 1] = Premultiply(green, alpha);
            output[offset + 2] = Premultiply(red, alpha);
        }

        return output;
    }

    private static byte Premultiply(byte channel, byte alpha) =>
        (byte)(channel * alpha / 255);
}
