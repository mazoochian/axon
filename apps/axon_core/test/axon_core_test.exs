defmodule AxonCoreTest do
  use ExUnit.Case
  doctest AxonCore

  test "greets the world" do
    assert AxonCore.hello() == :world
  end
end
