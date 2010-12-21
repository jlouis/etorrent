define(main_setup, `
/* General coloration and font setup */
rankdir=LR;
node [fontname="URW Gothic L",fontsize=12,shape=plaintext,labelfontname=Helvetica];
labeljust = l;
labelloc = t;

fontsize = 24;
fontname="URW Gothic L";

label = "Etorrent Supervisor Tree:";
')

define(sup_s, `$1 [label="$1", shape=box, color=red];')
define(sup_11, `$1 [label="$1", shape=box, color=blue];')
define(sup_1a, `$1 [label="$1", shape=box, color=green];')

define(suggest_link, `$1 -> $2 [style=dashed,color=lightgrey];')
define(link, `$1 -> $2')
digraph etorrent_sup {

main_setup

	subgraph cluster_legend {
	  label="Legend";
	  color="deepskyblue4";
	  fontsize=14;
		{ rank=same;
		  sup_s(`simple_one_for_one')
		  sup_11(`one_for_one')
		  sup_1a(`one_for_all')
		}
	}

	/* Top level */
	sup_1a(`etorrent_sup')

	/* Torrent Global */
	{ rank=same;
	  sup_1a(`listen_sup')
	  sup_11(`dht_sup')
	  sup_11(`dirwatcher_sup')
	  sup_11(`t_pool_sup')
	  sup_1a(`udp_tracker_sup')
        }

	link(`etorrent_sup', `listen_sup')
	link(`etorrent_sup', `dht_sup')
	link(`etorrent_sup', `dirwatcher_sup')
	link(`etorrent_sup', `t_pool_sup')
	link(`etorrent_sup', `udp_tracker_sup')

	/* UDP Tracking */
	sup_s(`udp_tracker_pool')
	sup_11(`udp_decoder_sup')

	link(`udp_tracker_sup', `udp_tracker_pool')
	link(`udp_tracker_sup', `udp_decoder_sup')

	/* Torrent Pool */
	subgraph cluster_torrent {
          label="Torrent";
	  color="deepskyblue4";
	  fontsize=14;

	  sup_1a(`t_sup')

	  { rank=same;
	    sup_11(`fs_pool')
	    sup_s(`peer_pool_sup')
          }

	  link(`t_sup', `fs_pool')
	  link(`t_sup', `peer_pool_sup')

 	  sup_1a(`peer_sup')
	  sup_1a(`file_io_sup')

	  suggest_link(`peer_pool_sup', `peer_sup')
	  suggest_link(`fs_pool', `file_io_sup')
	}

	suggest_link(`t_pool_sup', `t_sup')
}
