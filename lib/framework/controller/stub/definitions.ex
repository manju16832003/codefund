defmodule Framework.Controller.Stub.Definitions do
  import Framework.{Module, Path}
  use CodeFundWeb, :controller

  @all_actions [
    :index,
    :new,
    :create,
    :show,
    :edit,
    :update,
    :delete
  ]

  defmacro __using__([:all]) do
    quote do
      apply(__MODULE__, :config, [])
    end
    |> build_actions(@all_actions)
  end

  defmacro __using__([:all, except: exclusions]) when is_list(exclusions) do
    quote do
      apply(__MODULE__, :config, [])
    end
    |> build_actions(@all_actions -- exclusions)
  end

  defmacro __using__(actions) when is_list(actions) do
    quote do
      apply(__MODULE__, :config, [])
    end
    |> build_actions(actions)
  end

  @spec build_action(%Controller.Config{}, atom, list) :: Macro.t()
  def build_action(config, action, block) do
    quote do
      def unquote(action)(conn, params) do
        Framework.Controller.Stub.Definitions.define(
          unquote(action),
          unquote(block),
          unquote(config),
          conn,
          params
        )
      end
    end
  end

  def define(action, block, config, conn, params \\ %{}) do
    after_hooks = [
      success: block[:after_hooks][:success] || fn _object, _params -> [] end,
      error: block[:after_hooks][:error] || fn _conn, _params -> [] end
    ]

    params = merge_params(block, config, conn, params)

    conn = construct_conn(block, config, conn, params)

    action(
      action,
      config,
      conn,
      params,
      after_hooks
    )
  end

  @spec build_actions(Macro.t(), list) :: Macro.t()
  defp build_actions(config, actions) when is_list(actions) do
    for action <- actions do
      build_action(config, action, [])
    end
  end

  defp construct_conn(block, config, conn, params) do
    case Keyword.has_key?(block, :before_hook) do
      true ->
        assign(
          conn,
          block[:before_hook].(conn, params)
        )

      false ->
        conn
    end
    |> assign(block[:assigns] || [])
    |> put_private(:controller_config, config)
  end

  defp merge_params(block, config, conn, params) do
    case Keyword.has_key?(block, :inject_params) do
      true ->
        {key, value} = block[:inject_params].(conn, params)

        put_in(
          params,
          ["params", pretty(config.schema, :downcase, :singular), key],
          value
        )

      false ->
        params
    end
  end

  @spec assign(Plug.Conn.t(), list) :: Plug.Conn.t()
  defp assign(conn, assigns) do
    assigns = assigns |> Enum.into(%{}) |> Map.merge(conn.assigns)
    Map.put(conn, :assigns, assigns)
  end

  @spec action(atom, %Controller.Config{}, %Plug.Conn{}, map, list) :: %Plug.Conn{}
  defp action(:index, config, conn, params, _after_hooks) do
    try do
      case apply(module_name(config.schema, :context), paginate(config.schema), [
             current_user(conn),
             params
           ]) do
        {:ok, assigns} ->
          render(conn, "index.html", assigns)

        error ->
          conn
          |> put_flash(
            :error,
            "There was an error rendering #{pretty(config.schema, :upcase, :plural)}. #{
              inspect(error)
            }"
          )
          |> redirect(to: construct_path(conn, :index))
      end
    rescue
      exception ->
        report(
          :error,
          exception,
          "error rendering index #{pretty(config.schema, :upcase, :plural)}"
        )
    end
  end

  defp action(:new, config, conn, _params, _after_hooks) do
    conn
    |> put_private(:controller_config, config)
    |> render(
      CodeFundWeb.SharedView,
      "form_container.html",
      action: :create,
      conn: conn
    )
  end

  defp action(:create, config, conn, params, after_hooks) do
    module_name(config.schema, :context)
    |> apply(:"create_#{pretty(config.schema, :downcase, :singular)}", [
      fetch_post_params(config.schema, params)
    ])
    |> case do
      {:ok, object} ->
        after_hooks[:success].(object, params)

        conn =
          conn
          |> put_private(:controller_config, config)
          |> assign(:object, object)

        conn
        |> put_flash(:info, "#{pretty(config.schema, :upcase, :singular)} created successfully.")
        |> redirect(to: construct_path(conn, :show))

      {:error, changeset} ->
        report(:warning, "Changeset Error")
        error_assigns = after_hooks[:error].(conn, params)

        conn
        |> put_private(:controller_config, config)
        |> put_status(422)
        |> render(
          CodeFundWeb.SharedView,
          "form_container.html",
          Enum.concat(
            error_assigns,
            conn: conn,
            action: :create,
            changeset: changeset
          )
        )
    end
  end

  defp action(:show, config, conn, %{"id" => id}, _after_hooks) do
    conn
    |> put_private(:controller_config, config)
    |> render(
      "show.html",
      Keyword.new([
        {pretty(config.schema, :downcase, :singular) |> String.to_atom(), get!(config.schema, id)}
      ])
    )
  end

  defp action(:edit, config, conn, %{"id" => id}, _after_hooks) do
    object = get!(config.schema, id)
    current_user = current_user(conn)

    conn
    |> put_private(:controller_config, config)
    |> render(
      CodeFundWeb.SharedView,
      "form_container.html",
      Keyword.new([
        {pretty(config.schema, :downcase, :singular) |> String.to_atom(), object},
        {:object, object},
        {:action, :update},
        {:conn, conn},
        {:current_user, current_user}
      ])
    )
  end

  defp action(:update, config, conn, %{"id" => id} = params, after_hooks) do
    object = get!(config.schema, id)
    current_user = current_user(conn)

    module_name(config.schema, :context)
    |> apply(:"update_#{pretty(config.schema, :downcase, :singular)}", [
      object,
      fetch_post_params(config.schema, params)
    ])
    |> case do
      {:ok, object} ->
        after_hooks[:success].(object, params)

        conn =
          conn
          |> put_private(:controller_config, config)
          |> assign(:object, object)

        conn
        |> put_flash(:info, "#{pretty(config.schema, :upcase, :singular)} updated successfully.")
        |> redirect(to: construct_path(conn, :show))

      {:error, changeset} ->
        report(:warning, "Changeset Error")

        conn
        |> put_private(:controller_config, config)
        |> put_status(422)
        |> render(
          CodeFundWeb.SharedView,
          "form_container.html",
          Keyword.new([
            {pretty(config.schema, :downcase, :singular) |> String.to_atom(), object},
            {:object, object},
            {:action, :update},
            {:conn, conn},
            {:current_user, current_user},
            {:changeset, changeset}
          ])
          |> Keyword.merge(after_hooks[:error].(conn, params))
        )
    end
  end

  defp action(:delete, config, conn, %{"id" => id}, _after_hooks) do
    {:ok, object} =
      module_name(config.schema, :context)
      |> apply(:"delete_#{pretty(config.schema, :downcase, :singular)}", [get!(config.schema, id)])

    conn =
      conn
      |> assign(:object, object)

    conn
    |> put_private(:controller_config, config)
    |> put_flash(:info, "#{pretty(config.schema, :upcase, :singular)} deleted successfully.")
    |> redirect(to: construct_path(conn, :index))
  end

  @spec get!(String.t(), UUID.t()) :: struct
  defp get!(schema, id),
    do:
      apply(module_name(schema, :context), :"get_#{pretty(schema, :downcase, :singular)}!", [id])

  @spec current_user(%Plug.Conn{}) :: %CodeFund.Schema.User{}
  defp current_user(conn), do: conn.assigns.current_user

  @spec paginate(String.t()) :: atom
  defp paginate(schema), do: :"paginate_#{pretty(schema, :downcase, :plural)}"

  @spec fetch_object_params(String.t(), map) :: any()
  defp fetch_object_params(schema, params), do: params[pretty(schema, :downcase, :singular)]

  @spec fetch_post_params(String.t(), map) :: any()
  defp fetch_post_params(schema, params) do
    fetch_object_params(schema, params["params"])
  end
end
