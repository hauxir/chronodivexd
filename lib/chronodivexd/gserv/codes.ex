defmodule Chronodivexd.Gserv.Codes do
  @moduledoc "gserv numeric codes + binary opcodes."

  def api_version, do: 2

  def rpl_cvers_ok, do: 10
  def rpl_cvers_outdated, do: 11

  def rpl_logged_in, do: 100
  def rpl_already_logged_in, do: 101
  def rpl_bad_login, do: 103
  def rpl_too_many_login_attempts, do: 104

  def rpl_instance_created, do: 200
  def rpl_instance_exists, do: 201
  def rpl_instance_too_many, do: 202

  def rpl_instance_connected, do: 400
  def rpl_instance_nonexistent, do: 401
  def rpl_instance_not_allowed, do: 402
  def rpl_instance_already_started, do: 403
  def rpl_instance_vers_mismatch, do: 406

  def rpl_game_opts, do: 500
  def rpl_load_info, do: 600
  def rpl_game_start, do: 700
  def rpl_game_desync, do: 801
  def rpl_net_rate, do: 802
  def rpl_taunt, do: 803
  def rpl_player_disconnect, do: 804
  def rpl_privmsg_not_allowed, do: 805

  # Binary framing (first byte = prefix, second = code).
  def rpl_bin_prefix, do: 2
  def rpl_bin_game_actions, do: 1
  def rpl_bin_map_data, do: 2

  def req_bin_prefix, do: 2
  def req_bin_game_actions, do: 1
  def req_bin_game_state_hash, do: 2
  def req_bin_put_map, do: 3
  def req_bin_get_map, do: 4
end
