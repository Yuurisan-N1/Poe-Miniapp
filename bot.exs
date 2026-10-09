Code.require_file("utils/json.ex", __DIR__)
Code.require_file("utils/banner.ex", __DIR__)

defmodule PoeMiner do
  @moduledoc false

  @my_project "Poe Miner Miniapp"
  @base_url "https://timefi.up.railway.app"
  @origin "https://timefi.up.railway.app"
  @root __DIR__

  @reset "\e[0m"
  @bold "\e[1m"
  @red "\e[91m"
  @green "\e[92m"
  @yellow "\e[93m"

  def run do
    :logger.set_primary_config(:level, :error)
    install_signal_handler()

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    Banner.set_title(@my_project)
    Banner.show_banner(@my_project)

    accounts = load_lines("data.txt")

    if accounts == [] do
      red("File data.txt is empty, please add your initData entries")
      System.halt(1)
    end

    proxies = load_lines("proxy.txt")
    settings = load_settings()
    flags = read_flags(settings)

    loop(accounts, proxies, settings, flags, 1)
  end

  defp loop(accounts, proxies, settings, flags, cycle) do
    yellow("Starting automation cycle number #{cycle}")

    Enum.with_index(accounts)
    |> Enum.each(fn {account, index} ->
      if index > 0, do: IO.puts("")

      proxy = proxy_for(proxies, index)

      case proxy do
        nil -> :ok
        line -> yellow("Using proxy #{mask_proxy(line)}")
      end

      try do
        process_account(account, index, proxy, flags)
      rescue
        _error -> red("Account #{index + 1} was skipped after an error")
      end
    end)

    yellow("All accounts processed for cycle number #{cycle}")

    countdown(sleep_seconds(settings), "Next cycle starts in")
    Banner.show_banner(@my_project)
    loop(accounts, proxies, settings, flags, cycle + 1)
  end

  defp process_account(account, index, proxy, flags) do
    label = "#{index + 1}"

    case identity(account) do
      {:ok, id, username, first_name} ->
        case fetch_user(id, username, first_name, account, proxy) do
          {:ok, state} ->
            user = get(state, "user", %{})
            symbol = get(get(state, "settings", %{}), "tokenSymbol", "POE")

            green(
              "Welcome back #{clean_text(get(user, "firstName", "Unknown"), "user")} with balance #{format_amount(get(user, "poolWallet", 0))} #{symbol}"
            )

            process_mining(id, symbol, account, proxy)
            process_tasks(id, symbol, account, proxy, flags)
            process_referrals(id, account, proxy)
            :ok

          {:error, reason} ->
            red("Account #{label} fetch failed with #{clean_text(reason, "error")}")
        end

      {:error, reason} ->
        red("Account #{label} initData refused with #{clean_text(reason, "error")}")
    end
  end

  defp process_mining(id, symbol, account, proxy) do
    case fetch_user(id, "", "", account, proxy) do
      {:ok, state} ->
        mining = get(state, "miningState", %{})
        before = balance_of(state)

        cond do
          get(mining, "isMining", false) and
              get(mining, "remainingSeconds", 1) <= 0 ->
            claim_mining(id, before, symbol, account, proxy)

          get(mining, "isMining", false) ->
            yellow(
              "Mining is already running and finishes in #{format_duration(trunc(get(mining, "remainingSeconds", 0)))}"
            )

          true ->
            start_mining(id, account, proxy)
        end

      {:error, reason} ->
        red("Mining state could not be read with #{clean_text(reason, "error")}")
    end
  end

  defp start_mining(id, account, proxy) do
    case call("api/user/start-mining", %{"userId" => id}, account, proxy) do
      {:ok, _data} ->
        green("Mining session started and the cycle is now running")

      {:error, reason} ->
        text = clean_text(reason, "error")

        if String.contains?(String.upcase(to_string(reason)), "WALLET") do
          yellow("Mining was skipped because no TON wallet is linked")
        else
          red("Mining session start failed with #{text}")
        end
    end
  end

  defp claim_mining(id, before, symbol, account, proxy) do
    case call("api/user/claim-mining", %{"userId" => id}, account, proxy) do
      {:ok, _data} ->
        case fetch_user(id, "", "", account, proxy) do
          {:ok, fresh} ->
            gained = balance_of(fresh) - before

            if gained > 0 do
              green("Mining reward of #{format_amount(gained)} #{symbol} was claimed")
            else
              yellow("Mining claim answered but no reward was confirmed")
            end

          {:error, _} ->
            yellow("Mining claim answered but the balance was not confirmed")
        end

      {:error, reason} ->
        text = clean_text(reason, "error")

        cond do
          String.contains?(String.upcase(to_string(reason)), "NOTHING_TO_CLAIM") ->
            yellow("Mining session is still running, the next claim comes later")

          true ->
            red("Mining claim failed with #{text}")
        end
    end
  end

  defp process_tasks(id, symbol, account, proxy, flags) do
    case call_get("api/v2/tasks/list", account, proxy) do
      {:ok, data} ->
        tasks =
          get(data, "tasks", [])
          |> Enum.filter(fn task ->
            get(task, "isActive", true) and not get(task, "isCompleted", false)
          end)

        allowed = Enum.filter(tasks, fn task -> task_allowed?(task, flags) end)

        cond do
          tasks == [] ->
            yellow("Every available task was already completed")

          allowed == [] ->
            :ok

          true ->
            green("Found #{plural(length(allowed), "task")} to process")
            Enum.each(allowed, fn task -> claim_task(id, symbol, task, account, proxy) end)
        end

      {:error, reason} ->
        red("Task list could not be fetched with #{clean_text(reason, "error")}")
    end
  end

  defp task_allowed?(task, flags) do
    case get(task, "category", "") do
      "telegram" -> get(flags, "telegram_task", true)
      _ -> true
    end
  end

  defp claim_task(id, symbol, task, account, proxy) do
    title = shorten(clean_text(get(task, "title", "task"), "task"), "task", 18)
    task_id = get(task, "id")

    payload = %{"userId" => id, "taskId" => task_id}

    case call("api/v2/tasks/claim", payload, account, proxy) do
      {:ok, data} ->
        reward = get(data, "rewardAtf", get(task, "rewardAtf", 0))

        green(
          "Task #{title} claimed successfully earning #{format_amount(reward)} #{symbol}"
        )

      {:error, reason} ->
        code = String.upcase(to_string(reason))

        cond do
          String.contains?(code, "MUST_JOIN") or String.contains?(code, "NOT_JOINED") ->
            yellow("Task #{title} still needs a manual channel join")

          String.contains?(code, "ALREADY_COMPLETED") ->
            yellow("Task #{title} was already completed on this account")

          true ->
            red("Task #{title} was refused with #{clean_text(reason, "error")}")
        end
    end
  end

  defp process_referrals(id, account, proxy) do
    case call_get("api/referrals/#{id}", account, proxy) do
      {:ok, data} ->
        available = get(data, "referralRewardAvailable", 0)

        cond do
          available <= 0 ->
            yellow("No referral bonus is available for this account yet")

          true ->
            case call("api/referrals/claim-bonus", %{"userId" => id}, account, proxy) do
              {:ok, claimed} ->
                green(
                  "Referral bonus claimed earning #{format_amount(get(claimed, "reward", available))} POE"
                )

              {:error, reason} ->
                red("Referral bonus claim failed with #{clean_text(reason, "error")}")
            end
        end

      {:error, reason} ->
        red("Referral summary fetch failed with #{clean_text(reason, "error")}")
    end
  end

  defp fetch_user(id, username, first_name, account, proxy) do
    query =
      URI.encode_query(%{"username" => username, "firstName" => first_name})
      |> String.replace("%22", "")

    call_get("api/user/#{id}?#{query}", account, proxy)
  end

  defp balance_of(state) do
    case get(get(state, "user", %{}), "poolWallet", 0) do
      value when is_number(value) -> value
      _ -> 0
    end
  end

  defp identity(init_data) do
    with {:ok, params} <- parse_query(init_data),
         raw when is_binary(raw) <- Map.get(params, "user"),
         {:ok, user} <- YuurisanJSON.decode(URI.decode_www_form(raw)),
         id when not is_nil(id) <- get(user, "id") do
      {:ok, to_string(id), get(user, "username", ""), get(user, "first_name", "")}
    else
      nil -> {:error, "the user object is missing"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "initData could not be read"}
    end
  end

  defp parse_query(raw) do
    pairs =
      raw
      |> String.trim()
      |> String.split("&")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end
      end)

    if Enum.any?(pairs, fn {key, _} -> key == "hash" end) do
      {:ok, Map.new(pairs)}
    else
      {:error, "initData has no hash field"}
    end
  end

  defp call(path, payload, account, proxy) do
    case request(:post, path, payload, account, proxy) do
      {:ok, body} -> unwrap(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_get(path, account, proxy) do
    case request(:get, path, %{}, account, proxy) do
      {:ok, body} -> unwrap(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap(body) do
    case body do
      %{"error" => error} -> {:error, error}
      %{"success" => true} = data -> {:ok, data}
      %{} = data -> {:ok, data}
      _ -> {:ok, %{}}
    end
  end

  defp request(method, path, payload, init_data, proxy) do
    url = String.to_charlist(@base_url <> "/" <> path)
    {profile, auth} = proxy_setup(proxy)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"*/*"},
      {~c"accept-language", ~c"en-US,en;q=0.9"},
      {~c"origin", String.to_charlist(@origin)},
      {~c"referer", String.to_charlist(@origin <> "/")},
      {~c"x-telegram-init-data", String.to_charlist(init_data)},
      {~c"user-agent",
       ~c"Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"}
    ]

    options = [ssl: [verify: :verify_none], timeout: 30_000, connect_timeout: 15_000] ++ auth

    http_request =
      case method do
        :get -> {:get, {url, headers}}
        :post -> {:post, {url, headers, ~c"application/json", YuurisanJSON.encode(payload)}}
      end

    case :httpc.request(elem(http_request, 0), elem(http_request, 1), options, [body_format: :binary], profile) do
      {:ok, {{_, status, _}, _, response}} when status >= 200 and status < 300 ->
        case YuurisanJSON.decode(response) do
          {:ok, value} -> {:ok, value}
          {:error, _} -> {:error, "response could not be parsed"}
        end

      {:ok, {{_, status, _}, _, response}} ->
        case YuurisanJSON.decode(response) do
          {:ok, %{"error" => error}} -> {:error, error}
          {:ok, %{"message" => message}} -> {:error, message}
          {:ok, _} -> {:error, "server returned status #{status}"}
          {:error, _} -> {:error, "server returned status #{status}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp proxy_setup(nil), do: {:default, []}

  defp proxy_setup(line) do
    case parse_proxy(line) do
      {host, port, user, pass} -> proxy_profile(host, port, user, pass)
      {host, port} -> proxy_profile(host, port, "", "")
      nil -> {:default, []}
    end
  end

  defp proxy_profile(host, port, user, pass) do
    name = String.to_atom("proxy_#{host}_#{port}")
    address = {String.to_charlist(host), port}

    case :inets.start(:httpc, profile: name) do
      {:ok, _pid} -> :httpc.set_options([proxy: {address, []}, https_proxy: {address, []}], name)
      {:error, {:already_started, _pid}} -> :ok
      _ -> :ok
    end

    case user do
      "" -> {name, []}
      _ -> {name, [proxy_auth: {String.to_charlist(user), String.to_charlist(pass)}]}
    end
  end

  defp parse_proxy(line) do
    value =
      line
      |> String.trim()
      |> String.replace_prefix("http://", "")
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("socks5://", "")

    case String.split(value, "@") do
      [credentials, host_part] ->
        case String.split(credentials, ":") do
          [user, pass] -> with_host_port(host_part, user, pass)
          _ -> with_host_port(host_part, "", "")
        end

      [host_part] ->
        case String.split(host_part, ":") do
          [host, port] -> with_port(host, port)
          [host, port, user, pass] -> with_port_creds(host, port, user, pass)
          _ -> nil
        end
    end
  end

  defp with_host_port(host_part, user, pass) do
    case String.split(host_part, ":") do
      [host, port] -> with_port_creds(host, port, user, pass)
      _ -> nil
    end
  end

  defp with_port(host, port) do
    case Integer.parse(port) do
      {number, ""} -> {host, number}
      _ -> nil
    end
  end

  defp with_port_creds(host, port, user, pass) do
    case Integer.parse(port) do
      {number, ""} -> {host, number, user, pass}
      _ -> nil
    end
  end

  defp mask_proxy(line) do
    case parse_proxy(line) do
      {host, port, _user, _pass} -> "http://user:pass@#{mask_host(host)}:#{port}"
      {host, port} -> "http://user:pass@#{mask_host(host)}:#{port}"
      nil -> "http://user:pass@***:***"
    end
  end

  defp mask_host(host) do
    parts = String.split(host, ".")

    case parts do
      [a, _b, _c, d] ->
        "#{a}*****#{d}"

      _ ->
        if String.length(host) > 4 do
          String.slice(host, 0, 2) <> "*****" <> String.slice(host, -2, 2)
        else
          "***"
        end
    end
  end

  defp proxy_for([], _index), do: nil
  defp proxy_for(proxies, index), do: Enum.at(proxies, rem(index, length(proxies)))

  defp load_lines(name) do
    case File.read(Path.join(@root, name)) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:error, _} ->
        []
    end
  end

  defp load_settings do
    case File.read(Path.join(@root, "config.json")) do
      {:ok, content} ->
        case YuurisanJSON.decode(content) do
          {:ok, value} -> value
          {:error, _} -> default_settings()
        end

      {:error, _} ->
        settings = default_settings()
        File.write(Path.join(@root, "config.json"), YuurisanJSON.encode(settings))
        settings
    end
  end

  defp default_settings,
    do: %{"settings" => %{"sleep_seconds" => 3600, "telegram_task" => true}}

  defp read_flags(settings) do
    %{"telegram_task" => flag(settings, "telegram_task", true)}
  end

  defp flag(settings, key, fallback) do
    case get(get(settings, "settings", %{}), key, fallback) do
      value when is_boolean(value) ->
        value

      value when is_binary(value) ->
        case value |> String.trim() |> String.downcase() do
          text when text in ["true", "yes", "on", "1"] -> true
          text when text in ["false", "no", "off", "0"] -> false
          _ -> fallback
        end

      _ ->
        fallback
    end
  end

  defp sleep_seconds(settings) do
    case get(get(settings, "settings", %{}), "sleep_seconds", 3600) do
      value when is_integer(value) and value > 0 -> value
      value when is_float(value) and value > 0 -> trunc(value)
      _ -> 3600
    end
  end

  defp get(map, key, default \\ nil)
  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_other, _key, default), do: default

  defp clean_text(value, fallback) do
    text =
      value
      |> stringify()
      |> String.replace(
        ["[", "]", "|", "#", "!", "@", "$", "%", "^", "&", "*", "(", ")", "-"],
        " "
      )

    case String.split(text) |> Enum.join(" ") do
      "" -> fallback
      cleaned -> cleaned
    end
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp stringify({:failed_connect, _}), do: "no network connection"
  defp stringify({:timeout, _}), do: "the request timed out"
  defp stringify({:failed_connect, _, _}), do: "no network connection"
  defp stringify(value), do: inspect(value)

  defp format_amount(value) when is_float(value) do
    if abs(value) < 1 do
      :erlang.float_to_binary(value, decimals: 4)
    else
      :erlang.float_to_binary(value, decimals: 2)
    end
  end

  defp format_amount(value), do: to_string(value)

  defp install_signal_handler do
    handler = fn ->
      IO.write("\n" <> @red <> @bold <> "Script stopped by user" <> @reset <> "\n")
      System.halt(0)
    end

    try do
      System.trap_signal(:sigint, handler)
    rescue
      _ -> :ok
    end

    try do
      System.trap_signal(:sigterm, handler)
    rescue
      _ -> :ok
    end
  end

  defp shorten(value, fallback, limit) do
    text = to_string(value)

    case String.slice(text, 0, limit) do
      "" -> fallback
      short -> short
    end
  end

  defp plural(count, word) do
    if count == 1, do: "#{count} #{word}", else: "#{count} #{pluralize(word)}"
  end

  defp pluralize(word) do
    if String.ends_with?(word, "y") do
      String.slice(word, 0, String.length(word) - 1) <> "ies"
    else
      word <> "s"
    end
  end

  defp countdown(seconds, label) do
    left = max(trunc(seconds), 0)

    if left >= 1 do
      width = frame(label, left, 0)
      tick(left, label, width)
    end
  end

  defp tick(0, _label, width) do
    IO.write("\r" <> String.duplicate(" ", width) <> "\r")
  end

  defp tick(left, label, width) do
    width = frame(label, left, width)
    :timer.sleep(1000)
    tick(left - 1, label, width)
  end

  defp frame(label, left, width) do
    text = label <> " " <> format_duration(left)
    IO.write("\r" <> @yellow <> @bold <> text <> @reset)
    max(width, String.length(text))
  end

  defp format_duration(total) do
    days = div(total, 86_400)
    hours = div(rem(total, 86_400), 3600)
    minutes = div(rem(total, 3600), 60)
    seconds = rem(total, 60)

    if days > 0 do
      pad(days) <> ":" <> pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    else
      pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    end
  end

  defp pad(value), do: String.pad_leading(Integer.to_string(value), 2, "0")

  defp green(message), do: IO.puts(@green <> @bold <> message <> @reset)
  defp yellow(message), do: IO.puts(@yellow <> @bold <> message <> @reset)
  defp red(message), do: IO.puts(@red <> @bold <> message <> @reset)
end

PoeMiner.run()
