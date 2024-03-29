defmodule Tk do
  alias Jack.Tokeniser
  defstruct [:type, :val, :line]

  @type t :: %__MODULE__{
    type: Tokeniser.token_type_t(),
    val: String.t() | number | Tokeniser.keyword_t(),
    line: non_neg_integer
  }

  defimpl Inspect, for: Tk do
    import Inspect.Algebra

    def inspect(%Tk{type: _type, val: value}, opts) do
      # concat(["#", to_doc(type, opts), ": ", to_doc(value, opts)])
      to_doc(value, opts)
    end
  end
end

defmodule Jack.Tokeniser do
  @moduledoc """
  Given a sequence of lines as input, split them up into tokens.
  """

  @type keyword_t :: :class  | :method  | :function  | :constructor  |
   :int  | :boolean | :char  | :void  | :var |  :static  | :field  |
   :let  | :do  | :if  | :else  | :while  | :return  | :true  | :false  | :null  | :this

  @type token_type_t :: :keyword | :symbol | :identifier | :integer_constant | :string_constant | :comment

  @doc """
  Given a number of lines representing an entire file, return them as tokens.
  """
  def process(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.map(&tokenise/1)
    |> List.flatten()
  end

  @doc """
  Given a specific line, return a list of the tokens that compose that line.
  """
  def tokenise({{:comment, line}, lineno}) do
    %Tk{type: :comment, val: line, line: lineno}
  end

  def tokenise({{:nocomment, [line, inline_comment]}, lineno}) do
    [tokenise({{:nocomment, line}, lineno}), %Tk{type: :comment, val: inline_comment, line: lineno}]
  end

  def tokenise({{:nocomment, line}, lineno}) do
    Regex.split(~r/\".*\"/U, line, include_captures: true) # Split out quoted strings
    |> Enum.map(fn
       "\"" <> _rest = line -> # Don't split quoted strings further
          line

       line ->
          Regex.split(~r{\W}, line, trim: true, include_captures: true)
          |> Enum.reject(fn el -> el == " " end)
       end )
    |> List.flatten()
    |> Enum.map( fn el ->
      with type <- token_type(el) do
        case type do
          :keyword ->
            %Tk{type: :keyword, val: el |> String.to_atom(), line: lineno}
          :string_constant ->
            %Tk{type: :string_constant, val: String.slice(el, 1..-2), line: lineno}
          _ ->
            %Tk{type: type, val: el, line: lineno}
        end
      end
    end)
  end

  @spec token_type(any) :: token_type_t
  def token_type(var) do
    case var do
      var when var in ["class", "constructor", "function", "method", "field", "static", "var",
          "int", "char", "boolean", "void", "true", "false", "null", "this", "let", "do",
          "if", "else", "while", "return"] ->
            :keyword
      symbol when symbol in ["{", "}", "(", ")", "[", "]", ".",
          ",", ";", "+", "-", "*", "/", "&", "|", "<", ">", "=", "~"] ->
            :symbol
      "\"" <> _ ->
         :string_constant
      var ->
        case Integer.parse(var) do
          :error -> :identifier
          _ -> :integer_constant
        end
    end
  end
end
