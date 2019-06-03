defmodule StEl do # StructuredElement
  defstruct [:type, :els]
  @type t :: %__MODULE__{type: element_type(), els: list(Token.t())}

  @type element_type :: :class | :class_var_dec | :subroutine_dec | :parameter_list | :subroutine_body |
    :var_dec | :statements | :while_statement | :if_statement | :return_statement | :let_statement | :do_statement |
    :expression | :term | :expression_list

  defimpl Inspect, for: StEl do
    import Inspect.Algebra

    def inspect(%StEl{type: type, els: els}, opts) do
      concat(["#{type} ", to_doc(els, opts), ""])
    end
  end
end

defmodule Jack.Engine do
  @moduledoc """
  Effects the actual compilation output. Gets its input from a
  JackTokenizer and emits its parsed structure into an output file/stream. The
  output is generated by a series of compilexxx() routines, one for every syntactic
  element xxx of the Jack grammar. The contract between these routines is that each
  compilexxx() routine should read the syntactic construct xxx from the input,
  advance() the tokenizer exactly beyond xxx, and output the parsing of xxx. Thus,
  compilexxx() may only be called if indeed xxx is the next syntactic element of the
  input.

  CompileClass            Compiles a complete class.
  CompileClassVarDec      Compiles a static declaration or a field declaration.
  CompileSubroutine       Compiles a complete method, function, or constructor.
  compileParameterList    Compiles a (possibly empty) parameter list, not including the enclosing ‘‘()’’.
  compileVarDec           Compiles a var declaration.
  compileStatements       Compiles a sequence of statements, not including the enclosing ‘‘{}’’.
  compileDo               Compiles a do statement.
  compileLet              Compiles a let statement.
  compileWhile            Compiles a while statement.
  compileReturn           Compiles a return statement.
  compileIf               Compiles an if statement, possibly with a trailing else clause.
  CompileExpression       Compiles an expression.
  CompileTerm             Compiles a term. This routine is faced with a slight difficulty
                            when trying to decide between some of the alternative parsing
                            rules. Specifically, if the current token is an identifier, the routine
                            must distinguish between a variable, an array entry, and a
                            subroutine call. A single lookahead token, which may be one
                            of ‘‘[’’, ‘‘(’’, or ‘‘.’’ suffices to distinguish between the three possibilities.
                            Any other token is not part of this term and should not be advanced over.
  CompileExpressionList   Compiles a (possibly empty) comma-separated list of expressions.

  Non Terminal groupings:
  * class, classVarDec, subroutineDec, parameterList, subroutineBody, varDec;
  * statements, whileSatement, ifStatement, returnStatement, letStatement, doStatement;
  * expression, term, expressionList.

  Terminal Groupings
  * keyword, symbol, integerConstant, stringConstant, or identifier.
  """
  # These are super handy
  # IO.inspect(tokens, label: :tokens, depth: :infinite)
  # IO.inspect(acc, label: :acc, depth: :infinite)

  ################################## Program Structure ################################

  @doc """
  This will always be called first. The first
  """
  def compile([%Tk{val: :class} = class, class_name = %Tk{type: :identifier}, br = %Tk{val: "{"} | tokens], acc) do
    # Class declaration.
    # Class class_name { class_variable*, subroutine* }
    {remaining_tokens, class_elements} = compile_until_greedy(tokens, "}")
    {remaining_tokens, [%StEl{type: :class, els: [class, class_name, br] ++ Enum.reverse(class_elements) }] ++ acc}
  end


  def compile([%Tk{type: :keyword, val: val} = var_dec, type, name | tokens], acc) when val in [:field, :static] do
    # Class variable declaration.
    # field int x, y;
    {remaining_tokens, more_var_dec_elements} = compile_until_greedy(tokens, ";")
    {remaining_tokens, [%StEl{type: :class_var_dec, els: [var_dec, type, name] ++ Enum.reverse(more_var_dec_elements)}] ++ acc}
  end

  def compile([%Tk{type: :keyword, val: val} = rt_type, ret_type, name, br = %Tk{val: "("} | tokens], acc) when val in [:constructor, :function, :method, :void] do
    # Subroutine declaration.
    # ('constructor' | 'function' | 'method')
    # ('void' | type) subroutineName '(' parameterList ')'
    # subroutineBody

    # Apparently a parameter list doesn't include the braces ¯\_(ツ)_/¯
    {[%Tk{val: ")"} = cp, %Tk{val: "{"} = ob | remaining_tokens], parameter_list_tokens} = compile_until_no_greedy(tokens, ")")
    parameter_list = [%StEl{type: :parameter_list, els: Enum.reverse(parameter_list_tokens)}]

    # Build ourselves a subroutine body
    {[cb | body_remaining_tokens], subroutine_body_tokens} = compile_until_no_greedy(remaining_tokens, "}")
    {var_decs, statement_tokens} =
      subroutine_body_tokens
      |> Enum.reverse()
      |> Enum.split_while(fn
          %{type: type} when type in [:var_dec, :comment] -> true # lucky Tk and StEl both have a :type param ;)
          _ -> false
        end )

    statements = [%StEl{type: :statements, els: statement_tokens}]
    subroutine_body = [%StEl{type: :subroutine_body, els: [ob] ++ var_decs ++ statements ++ [cb]}]

    {body_remaining_tokens, [%StEl{type: :subroutine_dec, els: [rt_type, ret_type, name, br] ++ parameter_list ++ [cp] ++ Enum.reverse(subroutine_body)}] ++ acc}
  end

  def compile([%Tk{type: :keyword, val: :var} = var_dec, type, name | tokens], acc) do
    # Variable declaration.
    # var int x, y;
    {remaining_tokens, more_var_dec_elements} = compile_until_greedy(tokens, ";")
    {remaining_tokens, [%StEl{type: :var_dec, els: [var_dec, type, name] ++ Enum.reverse(more_var_dec_elements)}] ++ acc}
  end

  ##################################### Statements ###################################

  def compile([%Tk{type: :keyword, val: :let} = let, var_name,  %Tk{val: decider_val} = decider | tokens], acc) do
    # Let statement.
    # let x = v;
    # let x [expr] = v;
    {name_rem_tks, name} =
      if decider_val == "[" do
        {[cb, eq | remaining_tokens], assignee_expr_tks} = compile_until_no_greedy(tokens, "]")
          {remaining_tokens, [var_name, decider] ++ expression(Enum.reverse(assignee_expr_tks)) ++ [cb, eq]}
      else # Then the decider is the eq
        {tokens, [var_name, decider]}
      end
    {[%Tk{val: ";"} = sc | remaining_tokens], expression_els} = compile_until_no_greedy(name_rem_tks, ";")
    let_statement_els = Enum.reverse(expression(expression_els))

    {remaining_tokens, [%StEl{type: :let_statement, els: [let] ++ name ++ let_statement_els ++ [sc]}] ++ acc}
  end

  def compile([%Tk{type: :keyword, val: :if} = if_kw, op | tokens], acc) do
    # If statement.
    # 'if' '(' expression ')' '{' statements '}'
    # ('else' '{' statements '}')?

    {[%Tk{val: ")"} = cp, %Tk{val: "{"} = ob | if_statement_rem_tok], expression_els} = compile_until_no_greedy(tokens, ")")
    if_statement_expr_w_parens = [op] ++ expression(Enum.reverse(expression_els)) ++ [cp]

    {[%Tk{val: "}"} = cb | if_body_rem_tok], if_body} = compile_until_no_greedy(if_statement_rem_tok, "}")
    if_bod_w_braces = [ob, %StEl{type: :statements, els: Enum.reverse(if_body)}, cb]

    {remaining_tokens, else_body_w_braces} =
      case hd(if_body_rem_tok) do
        %Tk{val: :else} ->
          [else_kw, ob | pre_else_rem_tok] = if_body_rem_tok
          {[cb | else_body_rem_tok], tail_body} = compile_until_no_greedy(pre_else_rem_tok, "}")
          else_bod_w_braces = [else_kw, ob, %StEl{type: :statements, els: Enum.reverse(tail_body)}, cb]
          {else_body_rem_tok, else_bod_w_braces}

        _ -> {if_body_rem_tok, []}
      end

    {remaining_tokens, [%StEl{type: :if_statement, els: [if_kw] ++ if_statement_expr_w_parens ++ if_bod_w_braces ++ else_body_w_braces}] ++ acc}
  end

  def compile([%Tk{type: :keyword, val: :while} = while_kw, op | tokens], acc) do
    # While statement.
    # 'while' '(' expression ')' '{' statements '}'

    {[%Tk{val: ")"} = cp, %Tk{val: "{"} = ob | while_statement_rem_tok], expression_els} = compile_until_no_greedy(tokens, ")")
    while_statement_expr_w_parens = [op] ++ expression(Enum.reverse(expression_els)) ++ [cp]

    {[%Tk{val: "}"} = cb | remaining_tokens], while_body} = compile_until_no_greedy(while_statement_rem_tok, "}")
    while_bod_w_braces = [ob, %StEl{type: :statements, els: [Enum.reverse(while_body)]}, cb]

    {remaining_tokens, [%StEl{type: :while_statement, els: [while_kw] ++ while_statement_expr_w_parens ++ while_bod_w_braces}] ++ acc}
  end

  def compile([%Tk{type: :keyword, val: :do} = do_kw, name1,  %Tk{val: decider_val} = decider | tokens], acc) do
    # Do statement.
    # 'do' subroutineName '(' expressionList ')' | (className |
    # varName) '.' subroutineName '(' expressionList ')'

    # expressionList: (expression (',' expression)* )?

    {rem_name_toks, name} = # name includes the opening parenthesis here.
      case decider_val do
        "." ->
          [name2, %Tk{val: "("} = op | rem_name_toks] = tokens
          {rem_name_toks, [name1, decider, name2, op]}
        _ ->
          {tokens, [name1, decider]}
      end

    {[%Tk{val: ")"} = cp, %Tk{val: ";"} = sc | remaining_tokens], expression_els} = compile_until_no_greedy(rem_name_toks, ")")

    expressions = case expression_els do
      [] ->
        [%StEl{type: :expression_list, els: []}]

      _ ->
        [first_expr_toks | other_expr_toks] =
          expression_els
          |> Enum.reverse()
          |> Enum.chunk_by(fn
            %Tk{val: ","} -> true
            _ -> false
          end)

          other_exprs =
          case other_expr_toks do
            [] ->
              []
            [comma | toks] ->
              [comma | Enum.map_every(toks, 2, &expression/1)]
              |> Enum.flat_map(fn v -> v end) # Flatten the commas out of the list
          end

        first_expr = expression(first_expr_toks)
        [%StEl{type: :expression_list, els: first_expr ++ other_exprs}]
    end

    {remaining_tokens, [%StEl{type: :do_statement, els: [do_kw] ++ name ++ expressions ++ [cp, sc]}] ++ acc}
  end


  def compile([%Tk{type: :keyword, val: :return} = return_kw, %Tk{val: decider_val} = decider | tokens], acc) do
    # Return statement.
    # 'return' expression? ';'
    # IO.inspect(tokens, label: :tokens, depth: :infinite)
    # IO.inspect(acc, label: :acc, depth: :infinite)
    {remaining_tokens, return_expression} =
      case decider_val do
        ";" ->
          {tokens, [decider]}
        _ ->
          {[sc | remaining_tokens], expression_els} = compile_until_no_greedy(tokens, ";")
          {remaining_tokens, expression(Enum.reverse([decider] ++ expression_els)) ++ [sc]}
      end

    {remaining_tokens, [%StEl{type: :return_statement, els: [return_kw] ++ return_expression}] ++ acc}
  end

  def compile([%Tk{val: "("} = op | tokens], acc) do
    {[cp | remaining_tokens], expression_els} = compile_until_no_greedy(tokens, ")")
    compile(remaining_tokens, [%StEl{type: :term, els:  [op] ++ expression(Enum.reverse(expression_els)) ++ [cp]}] ++ acc)
  end


  ############################### no-ops and closing symbols #########################

  def compile([%Tk{val: ","} = comma | tokens], acc) do
    compile(tokens, [comma | acc])
  end

  def compile([%Tk{val: val} | _] = tokens, acc) when val in ["}", ";", ")", "]"] do
    {tokens, acc}
  end

  def compile([%Tk{type: type} = el | tokens], acc) when type in [:comment, :identifier, :keyword, :symbol, :integer_constant, :string_constant] do
    compile(tokens, [el | acc])
  end

  def compile([], acc), do: {[], Enum.reverse(acc)}


  @doc """
  Calls compile until we have the specified token returned at the end.
  Removes it and appends it to the head of the accumulator.
  """
  def compile_until_greedy(tokens, val) do
    {[tk | tokens], acc} = compile_until_no_greedy(tokens, val)
    {tokens, [tk | acc]}
  end

  @doc """
  Calls compile until the specified token is found at the start of `remaining_tokens`. Leaves the token
  at the head of `remaining_tokens`.
  """
  def compile_until_no_greedy([%Tk{} | _] = tokens, val), do: compile_until_no_greedy({tokens, []}, val)
  def compile_until_no_greedy({[%Tk{val: val} | _] = tokens, acc}, val) do
    {tokens, acc}
  end

  def compile_until_no_greedy({tokens, acc}, tk) do
    tokens
    |> compile(acc)
    |> compile_until_no_greedy(tk)
  end

  @spec expression(list(StEl.t() | Tk.t())) :: [StEl.t()]
  def expression([]), do: []
  def expression(tokens) do

    {[], terms} = compile_expr_until_no_greedy(tokens, [])
    # terms =
    # tokens
    #   |> Enum.map(fn expr -> %StEl{type: :term, els: [expr]} end)
    [%StEl{type: :expression, els: Enum.reverse(terms)}]
  end


  # def compile_expr([%Tk{type: :var_name} = tk, %Tk{val: decider_val} = decider | tokens], acc) do
  #   # varName | varName '[' expression ']'
  #   if decider_val == "[" do
  #     {[cb | remaining_tokens], array_expr_toks} = compile_expr_until_no_greedy(tokens, "]")
  #     {remaining_tokens, [decider] ++ Enum.reverse(expression(array_expr_toks)) ++ [cb] ++ acc}
  #   else
  #     {[decider] ++ tokens, [%StEl{type: :term, els: [tk]}] ++ acc}
  #   end
  # end

  # def compile_expr([%Tk{val: "("} = op | tokens], acc) do
  #   # Parse parentheses pairs into subexpressions
  #   {[cp | remaining_tokens], paren_expr_toks} = compile_expr_until_no_greedy(tokens, ")")
  #   paren_expr = Enum.reverse(expression(paren_expr_toks))
  #   {remaining_tokens, [op] ++ Enum.reverse(paren_expr) ++ [cp] ++ acc}
  # end

  def compile_expr([%{type: type} = tk | tokens], acc) when type in [:symbol, :term] do
    # Pass symbols and through
    {tokens, [tk | acc]}
  end

  def compile_expr([tk | tokens], acc) do
    # Catch everything
    {tokens, [%StEl{type: :term, els: [tk]}] ++ acc}
  end

  def compile_expr_until_no_greedy(tokens, val) when is_list(tokens), do: compile_expr_until_no_greedy({tokens, []}, val)
  def compile_expr_until_no_greedy({[], acc}, _val), do: {[], acc}
  def compile_expr_until_no_greedy({[%Tk{val: val} | _] = tokens, acc}, val) do
    {tokens, acc}
  end

  def compile_expr_until_no_greedy({tokens, acc}, tk) do
    tokens
    |> compile_expr(acc)
    |> compile_expr_until_no_greedy(tk)
  end
end
