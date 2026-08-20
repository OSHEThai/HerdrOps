using System.Security.Cryptography;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace HerdrOps.RuntimeTests;

/// <summary>
/// Validates decoded PNG evidence without using compressed file size as a visual proxy.
/// </summary>
internal static class PngEvidenceAssertions
{
    public static DecodedPngEvidence AssertValid(
        string path,
        int expectedWidth,
        int expectedHeight)
    {
        Assert.IsTrue(File.Exists(path), $"PNG evidence was not written: {path}");

        using var input = File.OpenRead(path);
        var decoder = new PngBitmapDecoder(
            input,
            BitmapCreateOptions.PreservePixelFormat,
            BitmapCacheOption.OnLoad);
        Assert.IsGreaterThan(0, decoder.Frames.Count, $"PNG has no decodable frames: {path}");

        var frame = decoder.Frames[0];
        Assert.AreEqual(expectedWidth, frame.PixelWidth, $"PNG width drifted: {path}");
        Assert.AreEqual(expectedHeight, frame.PixelHeight, $"PNG height drifted: {path}");

        var converted = new FormatConvertedBitmap(
            frame,
            PixelFormats.Bgra32,
            destinationPalette: null,
            alphaThreshold: 0);
        var stride = checked(converted.PixelWidth * 4);
        var pixels = new byte[checked(stride * converted.PixelHeight)];
        converted.CopyPixels(pixels, stride, 0);

        var pixelCount = checked((long)converted.PixelWidth * converted.PixelHeight);
        Assert.AreEqual(
            checked(pixelCount * 4),
            (long)pixels.LongLength,
            $"Decoded pixel buffer has an unexpected length: {path}");

        var firstPixel = pixels.AsSpan(0, 4).ToArray();
        var nonUniformPixelCount = 0L;
        var hasVisiblePixel = false;
        for (var offset = 0; offset < pixels.Length; offset += 4)
        {
            hasVisiblePixel |= pixels[offset + 3] != 0;
            if (!pixels.AsSpan(offset, 4).SequenceEqual(firstPixel))
            {
                nonUniformPixelCount++;
            }
        }

        Assert.IsTrue(hasVisiblePixel, $"PNG decoded to an empty transparent image: {path}");
        Assert.IsGreaterThan(
            0L,
            nonUniformPixelCount,
            $"PNG decoded to uniform visual content: {path}");

        return new DecodedPngEvidence(
            expectedWidth,
            expectedHeight,
            pixelCount,
            Convert.ToHexString(SHA256.HashData(pixels)),
            nonUniformPixelCount);
    }
}

internal readonly record struct DecodedPngEvidence(
    int Width,
    int Height,
    long PixelCount,
    string PixelSha256,
    long NonUniformPixelCount);
