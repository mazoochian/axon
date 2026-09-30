defmodule AxonCore.NetworkAddressTest do
  use ExUnit.Case, async: true

  alias AxonCore.NetworkAddress

  describe "private?/1" do
    test "blocks private, reserved and special-purpose IPv4 ranges" do
      for ip <- [
            {10, 0, 0, 1},
            {127, 0, 0, 1},
            {169, 254, 169, 254},
            {172, 16, 0, 1},
            {192, 168, 1, 1},
            {100, 64, 0, 1},
            {198, 18, 0, 1},
            {198, 19, 255, 255},
            {224, 0, 0, 1},
            {255, 255, 255, 255}
          ] do
        assert NetworkAddress.private?(ip), "expected #{inspect(ip)} to be private"
      end
    end

    test "allows public IPv4 addresses, including just outside 198.18/15" do
      for ip <- [{8, 8, 8, 8}, {198, 17, 255, 255}, {198, 20, 0, 1}, {1, 1, 1, 1}] do
        refute NetworkAddress.private?(ip), "expected #{inspect(ip)} to be public"
      end
    end

    test "blocks special IPv6 ranges, including multicast" do
      for ip <- [
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1},
            {0xFF02, 0, 0, 0, 0, 0, 0, 1},
            {0xFF0E, 0, 0, 0, 0, 0, 0, 0x101}
          ] do
        assert NetworkAddress.private?(ip), "expected #{inspect(ip)} to be private"
      end
    end

    test "unwraps IPv4-mapped and NAT64 addresses and re-checks the embedded IPv4" do
      assert NetworkAddress.private?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
      assert NetworkAddress.private?({0x64, 0xFF9B, 0, 0, 0, 0, 0x7F00, 0x0001})
      assert NetworkAddress.private?({0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE})
      refute NetworkAddress.private?({0x64, 0xFF9B, 0, 0, 0, 0, 0x0808, 0x0808})
    end

    test "allows a public IPv6 address" do
      refute NetworkAddress.private?({0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888})
    end
  end

  describe "check/1" do
    test "blocks a NAT64 literal wrapping loopback" do
      assert NetworkAddress.check("[64:ff9b::127.0.0.1]") == {:error, :blocked_address}
    end
  end
end
