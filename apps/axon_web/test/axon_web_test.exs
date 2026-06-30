defmodule AxonWebTest do
  use ExUnit.Case
  doctest AxonWeb

  test "greets the world" do
    assert AxonWeb.hello() == :world
  end
end
