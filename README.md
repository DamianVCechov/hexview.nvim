![Neovim HexView](/screenshot/screen.gif)

# hexview.nvim

A lightweight, pure Lua hex editor for Neovim.

`hexview.nvim` allows you to view and edit binary files directly inside Neovim without needing external tools like `xxd`. It features smart cursor navigation, synchronized Hex/ASCII editing, and visual dirty state tracking.

## ✨ Features

* **Pure Lua**: No external dependencies or binaries required.
* **Multithreaded loading**: File chunks are read and rendered by libuv worker threads (`uv.new_work`), spread across CPU cores. You can browse and edit the file while it loads; the statusline shows load progress.
* **Auto-detection**: Automatically enables itself for binary files or files containing null bytes.
* **Smart Editing**: Edit directly in the Hex column or the ASCII column.
* **Visual Feedback**: Highlights modified (dirty) bytes before saving.
* **Smart Navigation**: `h`/`l` jumps correctly between nibbles and columns, skipping separators.
* **Quick Search HEX string**: `/` locates and jumps to hex string

## ⚡ Performance

Loading is split into chunks that are read and hex-rendered in parallel by libuv worker threads; the main thread only splices the finished lines into the buffer. This keeps Neovim responsive on large files (hundreds of MB render in tens of seconds instead of minutes) and lets you start browsing immediately.

Two knobs:

* `UV_THREADPOOL_SIZE` environment variable (set before starting Neovim, default `4`): number of worker threads.
* `chunk_bytes` in `setup()` (default `262144`): chunk size; smaller chunks keep insert pauses shorter while loading.

```lua
require("hexview").setup({ chunk_bytes = 256 * 1024 })
```

Notes on large files:

* Saving is blocked while a load is in flight (and if a chunk failed to load), so an incomplete load can never write a truncated file.
* Searching (`/`, `n`) searches the portion loaded so far and tells you how much of the file is available.


![Neovim HexView](/screenshot/screen.png)

## 📦 Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
    "DamianVCechov/hexview.nvim",
    config = function()
        require("hexview").setup()
    end
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
    "DamianVCechov/hexview.nvim",
    config = function()
        require("hexview").setup()
    end
}
```

## 🚀 Usage
The plugin automatically activates when opening a binary file. You can also manually toggle it (implementation dependent) or trigger it by opening a file with binary set.

### Keymaps
Keymaps are set automatically within the hex buffer:
```
h   Left	Move:   left (smart jump between Hex and ASCII areas)
l   Right	Move:   right (smart jump between Hex and ASCII areas)
r	Replace Single: Replace the byte or nibble under the cursor.
R	Replace Mode:   Continuously type Hex or ASCII characters to overwrite data. Press Esc to exit.
/   Find:           Searching for hex strings in a file
n   Find next:       Continue searching
```
### Commands
`:Hex`                  Open actual file in hex editor

`:HexSet <columns>`     Dynamically change the number of bytes per line. Example: `:HexSet 16` (sets view to 16 bytes per line).

`:UnHex`                Save file and open in RAW mode.

`:w`                    Save file

### Open Neovim

`nvim binary.file`         Automatically activates, but RAW mode is in non binary

`nvim -b binary.file`      Better, RAW mode is in binary

`nvim -b +Hex`             Opens any file in hex mode instantly

### ⚙️ Configuration
Pass configuration options to the setup function.

```lua
require("hexview").setup({
    auto_columns = true,     -- Fit the number of bytes per line to the window
                             -- width (default). Re-fits automatically on resize.
    bytes_per_line = 16,     -- Fixed columns instead of adaptive sizing
                             -- (implies auto_columns = false).
})
```

* The view adapts to the screen width on open and on `VimResized`/`WinResized`, so lines never exceed the window.
* `:HexSet <columns>` sets a manual override and disables auto-fitting for the session.

## 🎨 Highlights
* The plugin defines the following highlight groups, which you can override in your colorscheme:

* HexViewOffset: Color of the memory address offset (left column).

* HexViewHeader: Color of the column headers.

* HexViewCursor: The custom cursor highlight in Hex/ASCII columns.

* HexViewChanged: Highlight for modified (dirty) bytes that haven't been saved yet.

* HexViewModeEdit: Statusline indicator when in Replace mode.

## 🚧 Known limitations
* Large files may be slow to render
* No undo history

## 🤝 Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

📄 License
MIT

© 2026 Damian V. Čechov 
