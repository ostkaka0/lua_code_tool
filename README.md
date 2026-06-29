# lua_code_tool

Single-file Lua tool for batch search/refactor/code generation over files.

## Dependencies

- Lua
- Lua modules: `lfs`, `inspect`, `luv`, `argparse`
- Optional: `fennel` for Fennel snippets / `.fnl` files

## Install dependencies

Arch Linux:

```sh
sudo pacman -S lua lua-filesystem lua-luv lua-argparse luarocks
sudo luarocks install inspect
```

Generic LuaRocks install:

```sh
sudo luarocks install luafilesystem inspect luv argparse
```
