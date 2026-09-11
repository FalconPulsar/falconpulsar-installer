// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Text;
using System.Text.Json.Nodes;
using FalconPulsar.Tray;

// Standalone regression checks, with no external test dependencies or live HTTP.
// Run: dotnet run --project windows/tests/configbackup-pagination
internal static class Program
{
    private static int passed;

    private static async Task<int> Main()
    {
        string isolatedHome = Path.Combine(Path.GetTempPath(), "fp-pagination-" + Guid.NewGuid().ToString("N"));
        string previousHome = ConfigBackup.FalconPulsarHomeDir;
        Directory.CreateDirectory(isolatedHome);
        ConfigBackup.FalconPulsarHomeDir = isolatedHome;
        try
        {
            await SeriesImportResults();
            await Success("default offset advances by item count",
                ["{\"series\":[{\"id\":1},{\"id\":2}],\"has_more\":true}",
                 "{\"series\":[{\"id\":3}],\"has_more\":true}",
                 "{\"series\":[{\"id\":4}],\"has_more\":false}"],
                [0, 2, 3], [1, 2, 3, 4]);
            await Success("explicit offset and existing query",
                ["{\"series\":[{\"id\":1}],\"has_more\":true,\"next_offset\":9}",
                 "{\"items\":[{\"id\":2}]}"],
                [0, 9], [1, 2], path: "/api/v1/series?asset_id=7");
            await Success("hyphenated section alias",
                ["{\"asset-types\":[{\"id\":1}]}"], [0], [1], section: "asset_types");
            await Success("legacy bare array", ["[{\"id\":1}]"], [0], [1]);
            await Success("empty terminal page",
                ["{\"series\":[{\"id\":1}],\"has_more\":true}", "{\"series\":[]}"],
                [0, 1], [1]);
            await Success("empty section", ["{\"series\":[]}"], [0], []);

            await Failure<ConfigBackup.BackupException>("later HTTP failure",
                _ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)));
            await Failure<ConfigBackup.BackupException>("later HTTP redirect",
                _ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.Found)));
            await Failure<HttpRequestException>("later transport failure",
                _ => throw new HttpRequestException("synthetic disconnected page"));

            var malformedPages = new (string Name, string Json)[]
            {
                ("malformed JSON", "{"),
                ("error-shaped success response", "{\"error\":\"unavailable\"}"),
                ("missing array", "{\"has_more\":false}"),
                ("null array", "{\"series\":null}"),
                ("object array", "{\"series\":{}}"),
                ("string array", "{\"series\":\"bad\"}"),
                ("invalid primary array cannot fall back to items", "{\"series\":null,\"items\":[]}"),
                ("null root", "null"),
                ("scalar root", "42"),
                ("string root", "\"bad\""),
                ("empty continuation", "{\"series\":[],\"has_more\":true,\"next_offset\":2}"),
                ("stalled continuation", "{\"series\":[{}],\"has_more\":true,\"next_offset\":1}"),
                ("backwards continuation", "{\"series\":[{}],\"has_more\":true,\"next_offset\":0}")
            };
            foreach (var page in malformedPages)
                await Failure<ConfigBackup.BackupException>(page.Name, _ => Reply(page.Json));
            foreach (string invalidFlag in new[] { "null", "\"true\"", "1", "0", "[]", "{}" })
                await Failure<ConfigBackup.BackupException>($"invalid has_more {invalidFlag}",
                    _ => Reply($"{{\"series\":[],\"has_more\":{invalidFlag}}}"));
            foreach (string invalidOffset in new[] { "null", "\"2\"", "true", "-1", "1.5", "2.0", "2e0", "2147483648", "[]", "{}" })
                await Failure<ConfigBackup.BackupException>($"invalid next_offset {invalidOffset}",
                    _ => Reply($"{{\"series\":[],\"next_offset\":{invalidOffset}}}"));

            await Failure<ConfigBackup.BackupException>("page cap exhaustion",
                _ => Reply("{\"series\":[{}],\"has_more\":true}"), maxIterations: 2);

            Console.WriteLine($"PASS: {passed} config backup pagination checks (fake HTTP only).");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"FAIL after {passed} checks: {exception}");
            return 1;
        }
        finally
        {
            ConfigBackup.FalconPulsarHomeDir = previousHome;
            Directory.Delete(isolatedHome, recursive: true);
        }
    }

    private static async Task Success(string name, string[] pages, int[] offsets, int[] ids,
        string section = "series", string path = "/api/v1/series")
    {
        using var handler = new FakeHandler(index => Reply(pages[index]));
        using var http = new HttpClient(handler);
        byte[] result = await ConfigBackup.HarvestPaginatedAsync(http, path, section);
        var output = JsonNode.Parse(result).AsObject();
        var actualIds = output[section].AsArray().Select(item => item["id"].GetValue<int>()).ToArray();
        Require(actualIds.SequenceEqual(ids), name + ": lost, repeated, or reordered items");
        Require(output["count"].GetValue<int>() == ids.Length, name + ": incorrect total count");
        Require(handler.Requests.Count == offsets.Length, name + ": unexpected page count");
        string separator = path.Contains('?') ? "&" : "?";
        for (int i = 0; i < offsets.Length; i++)
            Require(handler.Requests[i].PathAndQuery == $"{path}{separator}limit=1000&offset={offsets[i]}",
                name + ": wrong pagination query at page " + i);
        passed++;
    }

    private static async Task SeriesImportResults()
    {
        var cases = new (string Json, int Errors)[] {
            ("{\"results\":[{\"status\":\"created\"},{\"status\":\"exists\"}]}", 0),
            ("{\"results\":[{\"status\":\"created\"},{\"status\":\"error\",\"error\":\"storage type conflict\"}]}", 1),
            ("{\"results\":[{\"status\":\"updated\"},{\"status\":\"exists\"}]}", 1),
            ("{\"results\":[{\"status\":\"created\"}]}", 2),
            ("{\"results\":null}", 2), ("{}", 2), ("{", 2),
            ("{\"results\":[{\"status\":1},{\"status\":\"exists\"}]}", 2),
        };
        foreach (var (json, errors) in cases)
        {
            Require(ConfigBackup.CountSeriesImportErrors(Encoding.UTF8.GetBytes(json), 2) == errors, "bulk result: " + json);
            passed++;
        }
        using var handler = new FakeHandler(_ => Reply(cases[1].Json));
        using var http = new HttpClient(handler);
        ConfigBackup.LastImportErrorCount = 0;
        await ConfigBackup.PostSeriesBatchAsync(http, "https://test.invalid", new JsonArray(new JsonObject(), new JsonObject()));
        Require(ConfigBackup.LastImportErrorCount == 1, "HTTP 200 hid a failed series restore");
        passed++;
    }

    private static async Task Failure<TException>(string name,
        Func<int, Task<HttpResponseMessage>> failingPage, int maxIterations = 10_000)
        where TException : Exception
    {
        using var handler = new FakeHandler(index => index == 0
            ? Reply("{\"series\":[{\"id\":1}],\"has_more\":true}")
            : failingPage(index));
        using var http = new HttpClient(handler);
        try
        {
            await ConfigBackup.HarvestPaginatedAsync(http, "/api/v1/series", "series", maxIterations);
        }
        catch (TException)
        {
            Require(handler.Requests.Count == 2, name + ": failure did not occur on the second page");
            passed++;
            return;
        }
        throw new InvalidOperationException(name + ": returned a partial section instead of failing");
    }

    private static Task<HttpResponseMessage> Reply(string json) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
    {
        Content = new StringContent(json, Encoding.UTF8, "application/json")
    });

    private static void Require(bool condition, string failure)
    {
        if (!condition) throw new InvalidOperationException(failure);
    }

    private sealed class FakeHandler(Func<int, Task<HttpResponseMessage>> response) : HttpMessageHandler
    {
        internal List<Uri> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(request.RequestUri);
            return response(Requests.Count - 1);
        }
    }
}
