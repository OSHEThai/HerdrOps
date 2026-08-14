using System.Buffers;
using System.Text;

namespace HerdrOps.Infrastructure.Herdr;

internal sealed class HerdrJsonLineReader
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private readonly Stream _stream;
    private readonly int _maximumFrameBytes;
    private readonly byte[] _readBuffer;
    private readonly ArrayBufferWriter<byte> _pendingFrame;
    private int _bufferStart;
    private int _bufferEnd;

    public HerdrJsonLineReader(Stream stream, int maximumFrameBytes, int readBufferBytes = 8192)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumFrameBytes, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(readBufferBytes, 1);
        _stream = stream;
        _maximumFrameBytes = maximumFrameBytes;
        _readBuffer = new byte[Math.Min(readBufferBytes, maximumFrameBytes + 1)];
        _pendingFrame = new ArrayBufferWriter<byte>(Math.Min(maximumFrameBytes, 8192));
    }

    public async ValueTask<string> ReadAsync(CancellationToken cancellationToken)
    {
        while (true)
        {
            var newlineIndex = FindNewline();
            if (newlineIndex >= 0)
            {
                Append(_readBuffer.AsSpan(_bufferStart, newlineIndex - _bufferStart));
                _bufferStart = newlineIndex + 1;
                var bytes = _pendingFrame.WrittenSpan;
                if (bytes.Length > 0 && bytes[^1] == (byte)'\r')
                {
                    bytes = bytes[..^1];
                }

                if (bytes.Length == 0)
                {
                    throw new HerdrProtocolException("Herdr returned an empty JSON line.");
                }

                try
                {
                    var json = StrictUtf8.GetString(bytes);
                    _pendingFrame.Clear();
                    return json;
                }
                catch (DecoderFallbackException exception)
                {
                    throw new HerdrProtocolException(
                        "Herdr returned a frame that is not strict UTF-8.",
                        exception);
                }
            }

            if (_bufferStart < _bufferEnd)
            {
                Append(_readBuffer.AsSpan(_bufferStart, _bufferEnd - _bufferStart));
                _bufferStart = _bufferEnd;
            }

            var bytesRead = await _stream.ReadAsync(_readBuffer, cancellationToken).ConfigureAwait(false);
            if (bytesRead == 0)
            {
                if (_pendingFrame.WrittenCount == 0)
                {
                    throw new EndOfStreamException("The Herdr stream ended before the next frame.");
                }

                throw new HerdrProtocolException("The Herdr stream ended in the middle of a JSON line.");
            }

            _bufferStart = 0;
            _bufferEnd = bytesRead;
        }
    }

    private int FindNewline()
    {
        var relativeIndex = _readBuffer.AsSpan(_bufferStart, _bufferEnd - _bufferStart)
            .IndexOf((byte)'\n');
        return relativeIndex < 0 ? -1 : _bufferStart + relativeIndex;
    }

    private void Append(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length > _maximumFrameBytes - _pendingFrame.WrittenCount)
        {
            throw new HerdrProtocolException(
                $"Herdr JSON line exceeded the {_maximumFrameBytes}-byte limit.");
        }

        _pendingFrame.Write(bytes);
    }
}

internal static class HerdrJsonLineWriter
{
    public static async ValueTask WriteAsync(
        Stream stream,
        ReadOnlyMemory<byte> json,
        int maximumFrameBytes,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(stream);
        if (json.IsEmpty || json.Length > maximumFrameBytes)
        {
            throw new HerdrProtocolException(
                $"Outgoing Herdr JSON must contain 1 to {maximumFrameBytes} bytes.");
        }

        await stream.WriteAsync(json, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync("\n"u8.ToArray(), cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }
}
