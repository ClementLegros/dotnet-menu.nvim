#!/usr/bin/env bash
# Prepares what demo.tape records: a small solution to play with, and the
# plugins of the demo config, installed ahead of time so the recording does not
# show vim.pack cloning them.
#
#   DEMO_DIR   where the sample solution goes (default: /tmp/dotnet-menu-demo)
#
# Usage, from the repo root:
#   demo/setup.sh && vhs demo/demo.tape
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
demo_dir="${DEMO_DIR:-/tmp/dotnet-menu-demo}"

# A separate app name, so vim.pack keeps the demo's plugins AND its lockfile
# apart: under the default name it writes nvim-pack-lock.json into your own
# config directory, and installs every plugin already listed there.
export NVIM_APPNAME=dotnet-menu-demo

rm -rf "$demo_dir"
mkdir -p "$demo_dir/Shop"
cd "$demo_dir/Shop"

dotnet new sln --name Shop >/dev/null
dotnet new classlib --name Shop.Core --output Shop.Core >/dev/null
rm Shop.Core/Class1.cs

cat > Shop.Core/Product.cs <<'EOF'
namespace Shop.Core;

public class Product
{
    public string Name { get; set; } = "";
    public decimal Price { get; set; }
}
EOF

cat > Shop.Core/Order.cs <<'EOF'
namespace Shop.Core;

public class Order
{
    public List<Product> Lines { get; } = new();

    public decimal Total => Lines.Sum(line => line.Price);
}
EOF

dotnet sln add Shop.Core/Shop.Core.csproj >/dev/null
# roslyn_ls reads obj/project.assets.json: without a restore every framework
# type would show as an error in the recording.
dotnet restore >/dev/null

# Install the demo config's plugins now rather than on camera.
nvim --headless -u "$repo/demo/init.lua" +qa >/dev/null 2>&1

echo "Demo solution ready in $demo_dir/Shop"
