defmodule AxonCrypto.CanonicalJSONTest do
  use ExUnit.Case, async: true

  alias AxonCrypto.CanonicalJSON

  # Test vectors from Matrix spec:
  # https://spec.matrix.org/latest/appendices/#canonical-json

  describe "encode/1 spec test vectors" do
    test "empty object" do
      assert to_binary(%{}) == "{}"
    end

    test "single key" do
      assert to_binary(%{"one" => 1}) == ~s({"one":1})
    end

    test "keys sorted lexicographically" do
      assert to_binary(%{"b" => 2, "a" => 1}) == ~s({"a":1,"b":2})
    end

    test "nested object keys sorted" do
      assert to_binary(%{"b" => %{"c" => 3, "a" => 1}, "a" => 2}) ==
               ~s({"a":2,"b":{"a":1,"c":3}})
    end

    test "unicode string passthrough" do
      assert to_binary(%{"a" => "日本語"}) == ~s({"a":"日本語"})
    end

    test "string with backslash" do
      assert to_binary(%{"a" => "\\"}) == ~s({"a":"\\\\"})
    end

    test "string with double quote" do
      assert to_binary(%{"a" => "\""}) == ~s({"a":"\\""})
    end

    test "null value" do
      assert to_binary(%{"a" => nil}) == ~s({"a":null})
    end

    test "boolean true" do
      assert to_binary(%{"a" => true}) == ~s({"a":true})
    end

    test "boolean false" do
      assert to_binary(%{"a" => false}) == ~s({"a":false})
    end

    test "integer value" do
      assert to_binary(%{"a" => 1}) == ~s({"a":1})
    end

    test "negative integer" do
      assert to_binary(%{"a" => -1}) == ~s({"a":-1})
    end

    test "array value" do
      assert to_binary(%{"a" => [1, 2, 3]}) == ~s({"a":[1,2,3]})
    end

    test "empty array" do
      assert to_binary(%{"a" => []}) == ~s({"a":[]})
    end

    test "control character \\n escaped" do
      assert to_binary(%{"a" => "\n"}) == ~s({"a":"\\n"})
    end

    test "control character \\r escaped" do
      assert to_binary(%{"a" => "\r"}) == ~s({"a":"\\r"})
    end

    test "control character \\t escaped" do
      assert to_binary(%{"a" => "\t"}) == ~s({"a":"\\t"})
    end

    test "control character below 0x20 escaped as \\uXXXX" do
      # U+0001
      assert to_binary(%{"a" => <<1>>}) == ~s({"a":"\\u0001"})
    end

    test "spec example from Matrix appendix" do
      input = %{
        "one" => 1,
        "two" => "Two"
      }

      assert to_binary(input) == ~s({"one":1,"two":"Two"})
    end

    test "deeply nested sort" do
      input = %{"z" => %{"z" => 1, "a" => 2}, "a" => %{"z" => 3, "a" => 4}}

      assert to_binary(input) == ~s({"a":{"a":4,"z":3},"z":{"a":2,"z":1}})
    end

    test "float raises" do
      assert_raise ArgumentError, fn ->
        to_binary(%{"a" => 1.5})
      end
    end

    test "list of objects" do
      input = %{"events" => [%{"b" => 2, "a" => 1}, %{"d" => 4, "c" => 3}]}
      assert to_binary(input) == ~s({"events":[{"a":1,"b":2},{"c":3,"d":4}]})
    end
  end

  describe "encode_to_binary/1" do
    test "returns binary" do
      result = CanonicalJSON.encode_to_binary(%{"a" => 1})
      assert is_binary(result)
      assert result == ~s({"a":1})
    end
  end

  defp to_binary(value), do: CanonicalJSON.encode_to_binary(value)
end
