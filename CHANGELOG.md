# Changelog: Multithreaded Loading

**Multithreaded File Loading**

* File loading now runs through libuv worker threads (`uv.new_work`): chunks are read from disk and pre-rendered in parallel across CPU cores, and the main thread only splices finished lines into the buffer.
* The editor stays responsive and browsable while a large file loads; the statusline shows load progress and loading, searching and saving behave sensibly with partially loaded data.
* Saving is blocked while a load is in flight or incomplete, preventing truncated writes.
* Saving and searching assemble binary data by splicing chunks instead of copying byte-by-byte.
* `chunk_bytes` option added to `setup()`; `UV_THREADPOOL_SIZE` controls worker thread count.

# Changelog: Performance & Search Update

**🚀 Major Performance Boost**

* **Batch Rendering:** Large files now load instantly. We switched from line-by-line rendering to a single-pass update, drastically reducing API calls.


**Memory Optimization:** Reduced memory usage by storing data as raw strings instead of large tables.

 
**Faster Saving:** Saving files is now buffered and much quicker.



**✨ New Features**

* **Hex Search:** You can now search for hex sequences (e.g., `AA BB`).
* Press `/` to search.
* Press `n` to find the next occurrence.





**🛠 Under the Hood**
 
**Optimized Rendering:** Switched to native syntax highlighting for offsets to improve scrolling performance.
 
**Sparse Edits:** Only modified bytes are stored in memory, keeping the plugin lightweight.
