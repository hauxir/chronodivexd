defmodule Chronodivexd.Wol.Codes do
  @moduledoc "WOL numeric reply codes."

  def rpl_get_locale, do: 309
  def rpl_set_locale, do: 310
  def rpl_liststart, do: 321
  def rpl_list, do: 322
  def rpl_listend, do: 323
  def rpl_game_channel, do: 326
  def rpl_namreply, do: 353
  def rpl_endofnames, do: 366
  def rpl_motd, do: 372
  def rpl_motdstart, do: 375
  def rpl_endofmotd, do: 376
  def rpl_bad_login, do: 378
  def err_nosuchchannel, do: 403
  def err_channelisfull, do: 471
  def err_bannedfromchan, do: 474
  def err_badchannelkey, do: 475
  def err_gamehasclosed, do: 478
  def err_yourebannedcreep, do: 465
  def rpl_cvers_ok, do: 700
  def rpl_cvers_outdated, do: 701
  def rpl_login_queue, do: 720
  def err_server_full, do: 721
end
