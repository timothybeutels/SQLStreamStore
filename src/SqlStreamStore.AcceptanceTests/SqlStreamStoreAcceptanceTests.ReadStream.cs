﻿namespace SqlStreamStore
{
    using System.Collections.Generic;
    using System.Linq;
    using System.Threading.Tasks;
    using Shouldly;
    using SqlStreamStore.Infrastructure;
    using SqlStreamStore.Streams;
    using Xunit;

    public partial class StreamStoreAcceptanceTests
    {
        [Theory]
        [MemberData("GetReadStreamForwardsTheories")]
        public async Task Can_read_streams_forwards(ReadStreamTheory theory)
        {
            using(var fixture = GetFixture())
            {
                using(var eventStore = await fixture.GetStreamStore())
                {
                    await eventStore.AppendToStream("stream-1", ExpectedVersion.NoStream, CreateNewStreamMessages(1, 2, 3));
                    await eventStore.AppendToStream("stream-2", ExpectedVersion.NoStream, CreateNewStreamMessages(4, 5, 6));

                    var streamEventsPage =
                        await eventStore.ReadStreamForwards(theory.StreamId, theory.Start, theory.PageSize);

                    var expectedStreamEventsPage = theory.ExpectedStreamMessagesPage;
                    var expectedEvents = theory.ExpectedStreamMessagesPage.Messages.ToArray();

                    streamEventsPage.FromStreamVersion.ShouldBe(expectedStreamEventsPage.FromStreamVersion);
                    streamEventsPage.LastStreamVersion.ShouldBe(expectedStreamEventsPage.LastStreamVersion);
                    streamEventsPage.NextStreamVersion.ShouldBe(expectedStreamEventsPage.NextStreamVersion);
                    streamEventsPage.ReadDirection.ShouldBe(expectedStreamEventsPage.ReadDirection);
                    streamEventsPage.IsEndOfStream.ShouldBe(expectedStreamEventsPage.IsEndOfStream);
                    streamEventsPage.Status.ShouldBe(expectedStreamEventsPage.Status);
                    streamEventsPage.StreamId.ShouldBe(expectedStreamEventsPage.StreamId);
                    streamEventsPage.Messages.Length.ShouldBe(expectedStreamEventsPage.Messages.Length);

                    for (int i = 0; i < streamEventsPage.Messages.Length; i++)
                    {
                        var streamEvent = streamEventsPage.Messages.ToArray()[i];
                        var expectedEvent = expectedEvents[i];

                        streamEvent.EventId.ShouldBe(expectedEvent.EventId);
                        streamEvent.JsonData.ShouldBe(expectedEvent.JsonData);
                        streamEvent.JsonMetadata.ShouldBe(expectedEvent.JsonMetadata);
                        streamEvent.StreamId.ShouldBe(expectedEvent.StreamId);
                        streamEvent.StreamVersion.ShouldBe(expectedEvent.StreamVersion);
                        streamEvent.Type.ShouldBe(expectedEvent.Type);

                        // We don't care about StreamMessage.Checkpoint and StreamMessage.Checkpoint
                        // as they are non-deterministic
                    }
                }
            }
        }

        [Theory]
        [MemberData("GetReadStreamBackwardsTheories")]
        public async Task Can_read_streams_backwards(ReadStreamTheory theory)
        {
            using (var fixture = GetFixture())
            {
                using (var eventStore = await fixture.GetStreamStore())
                {
                    await eventStore.AppendToStream("stream-1", ExpectedVersion.NoStream, CreateNewStreamMessages(1, 2, 3));
                    await eventStore.AppendToStream("stream-2", ExpectedVersion.NoStream, CreateNewStreamMessages(4, 5, 6));

                    var streamEventsPage =
                        await eventStore.ReadStreamBackwards(theory.StreamId, theory.Start, theory.PageSize);

                    var expectedStreamEventsPage = theory.ExpectedStreamMessagesPage;
                    var expectedEvents = theory.ExpectedStreamMessagesPage.Messages.ToArray();

                    streamEventsPage.FromStreamVersion.ShouldBe(expectedStreamEventsPage.FromStreamVersion);
                    streamEventsPage.LastStreamVersion.ShouldBe(expectedStreamEventsPage.LastStreamVersion);
                    streamEventsPage.NextStreamVersion.ShouldBe(expectedStreamEventsPage.NextStreamVersion);
                    streamEventsPage.ReadDirection.ShouldBe(expectedStreamEventsPage.ReadDirection);
                    streamEventsPage.IsEndOfStream.ShouldBe(expectedStreamEventsPage.IsEndOfStream);
                    streamEventsPage.Status.ShouldBe(expectedStreamEventsPage.Status);
                    streamEventsPage.StreamId.ShouldBe(expectedStreamEventsPage.StreamId);
                    streamEventsPage.Messages.Length.ShouldBe(expectedStreamEventsPage.Messages.Length);

                    for (int i = 0; i < streamEventsPage.Messages.Length; i++)
                    {
                        var streamEvent = streamEventsPage.Messages.ToArray()[i];
                        var expectedEvent = expectedEvents[i];

                        streamEvent.EventId.ShouldBe(expectedEvent.EventId);
                        streamEvent.JsonData.ShouldBe(expectedEvent.JsonData);
                        streamEvent.JsonMetadata.ShouldBe(expectedEvent.JsonMetadata);
                        streamEvent.StreamId.ShouldBe(expectedEvent.StreamId);
                        streamEvent.StreamVersion.ShouldBe(expectedEvent.StreamVersion);
                        streamEvent.Type.ShouldBe(expectedEvent.Type);

                        // We don't care about StreamMessage.Checkpoint and StreamMessage.Checkpoint
                        // as they are non-deterministic
                    }
                }
            }
        }

        [Fact]
        public async Task When_read_non_exist_stream_forwards_then_should_get_StreamNotFound()
        {
            using(var fixture = GetFixture())
            {
                using(var eventStore = await fixture.GetStreamStore())
                {
                    var streamEventsPage =
                        await eventStore.ReadStreamForwards("stream-does-not-exist", StreamVersion.Start, 1);

                    streamEventsPage.Status.ShouldBe(PageReadStatus.StreamNotFound);
                }
            }
        }

        [Fact]
        public async Task When_read_non_exist_stream_backwards_then_should_get_StreamNotFound()
        {
            using (var fixture = GetFixture())
            {
                using (var eventStore = await fixture.GetStreamStore())
                {
                    var streamEventsPage =
                        await eventStore.ReadStreamBackwards("stream-does-not-exist", StreamVersion.End, 1);

                    streamEventsPage.Status.ShouldBe(PageReadStatus.StreamNotFound);
                }
            }
        }

        [Fact]
        public async Task When_read_deleted_stream_forwards_then_should_get_StreamNotFound()
        {
            using (var fixture = GetFixture())
            {
                using (var eventStore = await fixture.GetStreamStore())
                {
                    await eventStore.AppendToStream("stream-1", ExpectedVersion.NoStream, CreateNewStreamMessages(1, 2, 3));
                    await eventStore.DeleteStream("stream-1");

                    var streamEventsPage =
                        await eventStore.ReadStreamForwards("stream-1", StreamVersion.Start, 1);

                    streamEventsPage.Status.ShouldBe(PageReadStatus.StreamNotFound);
                }
            }
        }

        [Fact]
        public async Task When_read_deleted_stream_backwards_then_should_get_StreamNotFound()
        {
            using (var fixture = GetFixture())
            {
                using (var eventStore = await fixture.GetStreamStore())
                {
                    await eventStore.AppendToStream("stream-1", ExpectedVersion.NoStream, CreateNewStreamMessages(1, 2, 3));
                    await eventStore.DeleteStream("stream-1");

                    var streamEventsPage =
                        await eventStore.ReadStreamBackwards("stream-1", StreamVersion.Start, 1);

                    streamEventsPage.Status.ShouldBe(PageReadStatus.StreamNotFound);
                }
            }
        }

        // ReSharper disable once UnusedMethodReturnValue.Global
        public static IEnumerable<object[]> GetReadStreamForwardsTheories()
        {
            var theories = new[]
            {
                new ReadStreamTheory("stream-1", StreamVersion.Start, 2,
                    new StreamMessagesPage("stream-1", PageReadStatus.Success, 0, 2, 2, ReadDirection.Forward, false,
                          ExpectedStreamEvent("stream-1", 1, 0, SystemClock.GetUtcNow().UtcDateTime),
                          ExpectedStreamEvent("stream-1", 2, 1, SystemClock.GetUtcNow().UtcDateTime))),

                new ReadStreamTheory("not-exist", 1, 2,
                    new StreamMessagesPage("not-exist", PageReadStatus.StreamNotFound, 1, -1, -1, ReadDirection.Forward, true)),

                new ReadStreamTheory("stream-2", 1, 2,
                    new StreamMessagesPage("stream-2", PageReadStatus.Success, 1, 3, 2, ReadDirection.Forward, true,
                          ExpectedStreamEvent("stream-2", 5, 1, SystemClock.GetUtcNow().UtcDateTime),
                          ExpectedStreamEvent("stream-2", 6, 2, SystemClock.GetUtcNow().UtcDateTime)))
            };

            return theories.Select(t => new object[] { t });
        }

        public static IEnumerable<object[]> GetReadStreamBackwardsTheories()
        {
            var theories = new[]
            {
               new ReadStreamTheory("stream-1", StreamVersion.End, 2,
                    new StreamMessagesPage("stream-1", PageReadStatus.Success, -1, 0, 2, ReadDirection.Backward, false,
                          ExpectedStreamEvent("stream-1", 3, 2, SystemClock.GetUtcNow().UtcDateTime),
                          ExpectedStreamEvent("stream-1", 2, 1, SystemClock.GetUtcNow().UtcDateTime))),

                 new ReadStreamTheory("stream-1", StreamVersion.End, 4,
                    new StreamMessagesPage("stream-1", PageReadStatus.Success, -1, -1, 2, ReadDirection.Backward, true,
                          ExpectedStreamEvent("stream-1", 3, 2, SystemClock.GetUtcNow().UtcDateTime),
                          ExpectedStreamEvent("stream-1", 2, 1, SystemClock.GetUtcNow().UtcDateTime),
                          ExpectedStreamEvent("stream-1", 1, 0, SystemClock.GetUtcNow().UtcDateTime)))
            };

            return theories.Select(t => new object[] { t });
        }

        public class ReadStreamTheory
        {
            public readonly string StreamId;
            public readonly int Start;
            public readonly int PageSize;
            public readonly StreamMessagesPage ExpectedStreamMessagesPage;

            public ReadStreamTheory(
                string streamId,
                int start,
                int pageSize,
                StreamMessagesPage expectedStreamMessagesPage)
            {
                StreamId = streamId;
                Start = start;
                PageSize = pageSize;
                ExpectedStreamMessagesPage = expectedStreamMessagesPage;
            }
        }
    }
}