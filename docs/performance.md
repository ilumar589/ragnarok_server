Unrefined performance document:

1. Use explicit allocator type in every function as a parameter (I know you can assign an allocator to the context but I prefer visibility)
2. Use arena allocators as much as possible. Arena allocators for requests should take memory in chunks from the general purpose allocator.
3. Use fixed buffer allocatores where needed. If Odin doesn't have a separate fixed buffer allocator I think it has arena allocators where you can pass a fixed buffer
4. Use thread pool and the new non-blocking io
5. Each request should have an arena allocator where all the data is freed at the end of the http request
6. Use structure of arrays as much as possible
7. Please read the odin_highlights.md file to get a summary of what odin is capable of
8. Please take into account how arenas + thread pools + non blocking io interact