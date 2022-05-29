defmodule KinoDB.ConnectionCell do
  @moduledoc false

  # A smart cell used to establish connection to a database.

  use Kino.JS, assets_path: "lib/assets/connection_cell"
  use Kino.JS.Live
  use Kino.SmartCell, name: "Database connection"

  @default_port_by_type %{"postgres" => 5432, "mysql" => 3306}

  @impl true
  def init(attrs, ctx) do
    type = attrs["type"] || default_db_type()
    default_port = @default_port_by_type[type]

    fields = %{
      "variable" => Kino.SmartCell.prefixed_var_name("conn", attrs["variable"]),
      "type" => type,
      "hostname" => attrs["hostname"] || "localhost",
      "database_path" => attrs["database_path"] || "",
      "port" => attrs["port"] || default_port,
      "username" => attrs["username"] || "",
      "password" => attrs["password"] || "",
      "database" => attrs["database"] || "",
      "schema" => attrs["schema"] || "",
      "account_name" => attrs["account_name"] || "",
      "warehouse" => attrs["warehouse"] || "",
      "role" => attrs["role"] || "",
      "project_id" => attrs["project_id"] || "",
      "default_dataset_id" => attrs["default_dataset_id"] || "",
      "credentials" => attrs["credentials"] || %{}
    }

    {:ok, assign(ctx, fields: fields, missing_dep: missing_dep(fields))}
  end

  @impl true
  def handle_connect(ctx) do
    payload = %{
      fields: ctx.assigns.fields,
      missing_dep: ctx.assigns.missing_dep
    }

    {:ok, payload, ctx}
  end

  @impl true
  def handle_event("update_field", %{"field" => field, "value" => value}, ctx) do
    updated_fields = to_updates(ctx.assigns.fields, field, value)
    ctx = update(ctx, :fields, &Map.merge(&1, updated_fields))

    missing_dep = missing_dep(ctx.assigns.fields)

    ctx =
      if missing_dep == ctx.assigns.missing_dep do
        ctx
      else
        broadcast_event(ctx, "missing_dep", %{"dep" => missing_dep})
        assign(ctx, missing_dep: missing_dep)
      end

    broadcast_event(ctx, "update", %{"fields" => updated_fields})

    {:noreply, ctx}
  end

  defp to_updates(_fields, "port", value) do
    port =
      case Integer.parse(value) do
        {n, ""} -> n
        _ -> nil
      end

    %{"port" => port}
  end

  defp to_updates(_fields, "type", value) do
    %{"type" => value, "port" => @default_port_by_type[value]}
  end

  defp to_updates(fields, "variable", value) do
    if Kino.SmartCell.valid_variable_name?(value) do
      %{"variable" => value}
    else
      %{"variable" => fields["variable"]}
    end
  end

  defp to_updates(_fields, field, value), do: %{field => value}

  @default_keys ["type", "variable"]

  @impl true
  def to_attrs(%{assigns: %{fields: fields}}) do
    connection_keys =
      case fields["type"] do
        "sqlite" ->
          ["database_path"]

        "bigquery" ->
          ~w|project_id default_dataset_id credentials|

        "snowflake" ->
          ~w|hostname username password account_name database schema role warehouse|

        type when type in ["postgres", "mysql"] ->
          ~w|database hostname port username password|
      end

    Map.take(fields, @default_keys ++ connection_keys)
  end

  @impl true
  def to_source(attrs) do
    attrs |> to_quoted() |> Kino.SmartCell.quoted_to_string()
  end

  defp to_quoted(%{"type" => "sqlite"} = attrs) do
    quote do
      opts = [database: unquote(attrs["database_path"])]

      {:ok, unquote(quoted_var(attrs["variable"]))} = Kino.start_child({Exqlite, opts})
    end
  end

  defp to_quoted(%{"type" => "postgres"} = attrs) do
    quote do
      opts = unquote(shared_options(attrs))

      {:ok, unquote(quoted_var(attrs["variable"]))} = Kino.start_child({Postgrex, opts})
    end
  end

  defp to_quoted(%{"type" => "mysql"} = attrs) do
    quote do
      opts = unquote(shared_options(attrs))

      {:ok, unquote(quoted_var(attrs["variable"]))} = Kino.start_child({MyXQL, opts})
    end
  end

  # TODO: Support :refresh_token and :metadata for Goth source type
  # See: https://github.com/peburrows/goth/blob/e62ca4afddfabdb3d599c3594fee02c49a2350e4/lib/goth/token.ex#L159-L172
  defp to_quoted(%{"type" => "bigquery"} = attrs) do
    quote do
      credentials = unquote(Macro.escape(attrs["credentials"]))

      opts = [
        name: ReqBigQuery.Goth,
        http_client: &Req.request/1,
        source: {:service_account, credentials, []}
      ]

      {:ok, _pid} = Kino.start_child({Goth, opts})

      unquote(quoted_var(attrs["variable"])) =
        Req.new(http_errors: :raise)
        |> ReqBigQuery.attach(
          goth: ReqBigQuery.Goth,
          project_id: unquote(attrs["project_id"]),
          default_dataset_id: unquote(attrs["default_dataset_id"])
        )

      :ok
    end
  end

  defp to_quoted(%{"type" => "snowflake"} = attrs) do
    quote do
        opts = [
          host: unquote(attrs["hostname"]),
          username: unquote(attrs["username"]),
          password: unquote(attrs["password"]),
          database: unquote(attrs["database"]),
          schema: unquote(attrs["schema"]),
          account_name: unquote(attrs["account_name"]),
          role: unquote(attrs["role"]),
          warehouse: unquote(attrs["warehouse"]),
        ]

      {:ok, unquote(quoted_var(attrs["variable"]))} = Kino.start_child({SnowflakeEx, opts})
    end
  end

  defp shared_options(attrs) do
    quote do
      [
        hostname: unquote(attrs["hostname"]),
        port: unquote(attrs["port"]),
        username: unquote(attrs["username"]),
        password: unquote(attrs["password"]),
        database: unquote(attrs["database"])
      ]
    end
  end

  defp quoted_var(string), do: {String.to_atom(string), [], nil}

  defp default_db_type() do
    cond do
      Code.ensure_loaded?(Postgrex) -> "postgres"
      Code.ensure_loaded?(MyXQL) -> "mysql"
      Code.ensure_loaded?(Exqlite) -> "sqlite"
      Code.ensure_loaded?(ReqBigQuery) -> "bigquery"
      Code.ensure_loaded?(SnowflakeEx) -> "snowflake"
      true -> "postgres"
    end
  end

  defp missing_dep(%{"type" => "postgres"}) do
    unless Code.ensure_loaded?(Postgrex) do
      ~s/{:postgrex, "~> 0.16.3"}/
    end
  end

  defp missing_dep(%{"type" => "mysql"}) do
    unless Code.ensure_loaded?(MyXQL) do
      ~s/{:myxql, "~> 0.6.2"}/
    end
  end

  defp missing_dep(%{"type" => "sqlite"}) do
    unless Code.ensure_loaded?(Exqlite) do
      ~s/{:exqlite, "~> 0.11.0"}/
    end
  end

  defp missing_dep(%{"type" => "bigquery"}) do
    unless Code.ensure_loaded?(ReqBigQuery) do
      ~s|{:req_bigquery, github: "livebook-dev/req_bigquery"}|
    end
  end

  defp missing_dep(%{"type" => "snowflake"}) do
    unless Code.ensure_loaded?(SnowflakeEx) do
      ~s|{:snowflake_elixir, github: "joshuataylor/snowflake_elixir"}|
    end
  end

  defp missing_dep(_ctx), do: nil
end
