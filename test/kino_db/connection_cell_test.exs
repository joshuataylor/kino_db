defmodule KinoDB.ConnectionCellTest do
  use ExUnit.Case, async: true

  import Kino.Test

  alias KinoDB.ConnectionCell

  setup :configure_livebook_bridge

  describe "initialization" do
    test "returns default source when started with missing attrs" do
      {_kino, source} = start_smart_cell!(ConnectionCell, %{"variable" => "conn"})

      assert source ==
               """
               opts = [hostname: "localhost", port: 5432, username: "", password: "", database: ""]
               {:ok, conn} = Kino.start_child({Postgrex, opts})\
               """
    end

    test "restores source code from attrs" do
      attrs = %{
        "variable" => "db",
        "type" => "mysql",
        "hostname" => "localhost",
        "port" => 4444,
        "username" => "admin",
        "password" => "pass",
        "database" => "default"
      }

      {_kino, source} = start_smart_cell!(ConnectionCell, attrs)

      assert source ==
               """
               opts = [
                 hostname: "localhost",
                 port: 4444,
                 username: "admin",
                 password: "pass",
                 database: "default"
               ]

               {:ok, db} = Kino.start_child({MyXQL, opts})\
               """
    end

    test "restores source code from attrs with SQLite3" do
      attrs = %{
        "variable" => "db",
        "type" => "sqlite",
        "database_path" => "/path/to/sqlite3.db"
      }

      {_kino, source} = start_smart_cell!(ConnectionCell, attrs)

      assert source ==
               """
               opts = [database: "/path/to/sqlite3.db"]
               {:ok, db} = Kino.start_child({Exqlite, opts})\
               """
    end

    test "restores source code from attrs with BigQuery" do
      attrs = %{
        "variable" => "db",
        "type" => "bigquery",
        "project_id" => "",
        "credentials" => %{},
        "default_dataset_id" => ""
      }

      {_kino, source} = start_smart_cell!(ConnectionCell, attrs)

      assert source ==
               """
               credentials = %{}

               opts = [
                 name: ReqBigQuery.Goth,
                 http_client: &Req.request/1,
                 source: {:service_account, credentials, []}
               ]

               {:ok, _pid} = Kino.start_child({Goth, opts})

               db =
                 Req.new(http_errors: :raise)
                 |> ReqBigQuery.attach(goth: ReqBigQuery.Goth, project_id: "", default_dataset_id: "")

               :ok\
               """
    end

    test "restores source code from attrs with Snowflake" do
      attrs = %{
        "variable" => "db",
        "type" => "snowflake",
        "hostname" => "https://example.com",
        "username" => "admin",
        "password" => "pass",
        "database" => "default",
        "schema" => "foobar"
      }

      {kino, source} = start_smart_cell!(ConnectionCell, attrs)

      require IEx
      IEx.pry

      assert source ==
               """
               credentials = %{}

               {:ok, _pid} = Kino.start_child({Goth, opts})

               db =
                 Req.new(http_errors: :raise)
                 |> ReqBigQuery.attach(goth: ReqBigQuery.Goth, project_id: "", default_dataset_id: "")

               :ok\
               """
    end
  end

  test "when a field changes, broadcasts the change and sends source update" do
    {kino, _source} = start_smart_cell!(ConnectionCell, %{"variable" => "conn"})

    push_event(kino, "update_field", %{"field" => "hostname", "value" => "myhost"})

    assert_broadcast_event(kino, "update", %{"fields" => %{"hostname" => "myhost"}})

    assert_smart_cell_update(kino, %{"hostname" => "myhost"}, """
    opts = [hostname: "myhost", port: 5432, username: "", password: "", database: ""]
    {:ok, conn} = Kino.start_child({Postgrex, opts})\
    """)
  end

  test "when an invalid variable name is set, restores the previous value" do
    {kino, _source} = start_smart_cell!(ConnectionCell, %{"variable" => "db"})

    push_event(kino, "update_field", %{"field" => "variable", "value" => "DB"})

    assert_broadcast_event(kino, "update", %{"fields" => %{"variable" => "db"}})
  end

  test "when the database type changes, restores the default port for that database" do
    {kino, _source} =
      start_smart_cell!(ConnectionCell, %{
        "variable" => "conn",
        "type" => "postgres",
        "port" => 5432
      })

    push_event(kino, "update_field", %{"field" => "type", "value" => "mysql"})

    assert_broadcast_event(kino, "update", %{"fields" => %{"type" => "mysql", "port" => 3306}})

    assert_smart_cell_update(kino, %{"type" => "mysql", "port" => 3306}, """
    opts = [hostname: "localhost", port: 3306, username: "", password: "", database: ""]
    {:ok, conn} = Kino.start_child({MyXQL, opts})\
    """)
  end
end
