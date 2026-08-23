using System.IO;
using HerdrOps.App.RuntimeEvidence;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class RendererTargetObservationProducerTests
{
    [TestMethod]
    public void ParseRequestAcceptsOnlyExactGovernedFirstRequest()
    {
        var request = RendererTargetObservationProducer.ParseRequest(
            "{\"protocol\":\"V02RendererTargetObservation\",\"version\":1,\"issue\":149,\"stage\":\"Startup\",\"ordinal\":0}",
            0);

        Assert.AreEqual("Startup", request.Stage);
        Assert.AreEqual(0, request.Ordinal);
    }

    [TestMethod]
    [DataRow("{\"protocol\":\"V02RendererTargetObservation\",\"protocol\":\"V02RendererTargetObservation\",\"version\":1,\"issue\":149,\"stage\":\"Startup\",\"ordinal\":0}")]
    [DataRow("{\"version\":1,\"protocol\":\"V02RendererTargetObservation\",\"issue\":149,\"stage\":\"Startup\",\"ordinal\":0}")]
    [DataRow("{\"protocol\":\"V02RendererTargetObservation\",\"version\":1,\"issue\":149,\"stage\":\"PreFirstWindow\",\"ordinal\":0}")]
    [DataRow("{\"protocol\":\"V02RendererTargetObservation\",\"version\":1,\"issue\":149,\"stage\":\"Startup\",\"ordinal\":1}")]
    [DataRow("{\"protocol\":\"wrong\",\"version\":1,\"issue\":149,\"stage\":\"Startup\",\"ordinal\":0}")]
    public void ParseRequestRejectsDuplicateReorderedOrCrossStageClaims(string json)
    {
        Assert.ThrowsExactly<InvalidDataException>(
            () => RendererTargetObservationProducer.ParseRequest(json, 0));
    }

    [TestMethod]
    public void StablePngReadBindsSameHandleBytesAndDimensions()
    {
        var path = Path.Combine(Path.GetTempPath(), $"renderer-png-{Guid.NewGuid():N}.png");
        try
        {
            File.WriteAllBytes(path, Convert.FromBase64String(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z7pAAAAAASUVORK5CYII="));

            var observed = RendererTargetObservationProducer.ReadStablePng(path);

            Assert.AreEqual(1, observed.Width);
            Assert.AreEqual(1, observed.Height);
            Assert.AreEqual(new FileInfo(path).Length, observed.Bytes);
            StringAssert.Matches(observed.Sha256, new System.Text.RegularExpressions.Regex("^[0-9A-F]{64}$"));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [TestMethod]
    public void StablePngReadRejectsHeaderOnlyForgery()
    {
        var path = Path.Combine(Path.GetTempPath(), $"renderer-forged-{Guid.NewGuid():N}.png");
        try
        {
            File.WriteAllBytes(path, new byte[24]);
            Assert.ThrowsExactly<InvalidDataException>(
                () => RendererTargetObservationProducer.ReadStablePng(path));
        }
        finally
        {
            File.Delete(path);
        }
    }
}
