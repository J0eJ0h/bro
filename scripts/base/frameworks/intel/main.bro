##! The intelligence framework provides a way to store and query intelligence data
##! (e.g. IP addresses, URLs and hashes). The intelligence items can be associated
##! with metadata to allow informed decisions about matching and handling.

@load base/frameworks/notice

module Intel;

export {
	redef enum Log::ID += { LOG };
	
	## Enum type to represent various types of intelligence data.
	type Type: enum {
		## An IP address.
		ADDR,
		## A subnet in CIDR notation.
		SUBNET,
		## A complete URL without the prefix ``"http://"``.
		URL,
		## Software name.
		SOFTWARE,
		## Email address.
		EMAIL,
		## DNS domain name.
		DOMAIN,
		## A user name.
		USER_NAME,
		## Certificate SHA-1 hash.
		CERT_HASH,
		## Public key MD5 hash. (SSH server host keys are a good example.)
		PUBKEY_HASH,
	};

	## Set of intelligence data types.
	type TypeSet: set[Type];

	## Data about an :bro:type:`Intel::Item`.
	type MetaData: record {
		## An arbitrary string value representing the data source. This
		## value is used as unique key to identify a metadata record in
		## the scope of a single intelligence item.
		source:      string;
		## A freeform description for the data.
		desc:        string      &optional;
		## A URL for more information about the data.
		url:         string      &optional;
	};
	
	## Represents a piece of intelligence.
	type Item: record {
		## The intelligence indicator.
		indicator:      string;

		## The type of data that the indicator field represents.
		indicator_type: Type;
		
		## Metadata for the item. Typically represents more deeply
		## descriptive data for a piece of intelligence.
		meta:           MetaData;
	};
	
	## Enum to represent where data came from when it was discovered.
	## The convention is to prefix the name with ``IN_``.
	type Where: enum {
		## A catchall value to represent data of unknown provenance.
		IN_ANYWHERE,
	};

	## Information about a piece of "seen" data.
	type Seen: record {
		## The string if the data is about a string.
		indicator:       string        &log &optional;

		## The type of data that the indicator represents.
		indicator_type:  Type          &log &optional;

		## If the indicator type was :bro:enum:`Intel::ADDR`, then this
		## field will be present.
		host:            addr          &optional;

		## Where the data was discovered.
		where:           Where         &log;

		## The name of the node where the match was discovered.
		node:            string        &optional &log;

		## If the data was discovered within a connection, the
		## connection record should go here to give context to the data.
		conn:            connection    &optional;

		## If the data was discovered within a connection, the
		## connection uid should go here to give context to the data.
		## If the *conn* field is provided, this will be automatically
		## filled out.
		uid:             string        &optional;
	};

	## Record used for the logging framework representing a positive
	## hit within the intelligence framework.
	type Info: record {
		## Timestamp when the data was discovered.
		ts:       time           &log;

		## If a connection was associated with this intelligence hit,
		## this is the uid for the connection
		uid:      string         &log &optional;
		## If a connection was associated with this intelligence hit,
		## this is the conn_id for the connection.
		id:       conn_id        &log &optional;

		## Where the data was seen.
		seen:     Seen           &log;
		## Which indicator types matched.
		matched:  TypeSet        &log;
		## Sources which supplied data that resulted in this match.
		sources:  set[string]    &log &default=string_set();
	};

	## Function to insert intelligence data. If the indicator is already
	## present, the associated metadata will be added to the indicator. If
	## the indicator already contains a metadata record from the same source,
	## the existing metadata record will be updated.
	global insert: function(item: Item);

	## Function to remove intelligence data. If purge_indicator is set, the
	## given metadata is ignored and the indicator is removed completely.
	global remove: function(item: Item, purge_indicator: bool &default = F);

	## Function to declare discovery of a piece of data in order to check
	## it against known intelligence for matches.
	global seen: function(s: Seen);

	## Event to represent a match in the intelligence data from data that
	## was seen. On clusters there is no assurance as to when this event
	## will be generated so do not assume that arbitrary global state beyond
	## the given data will be available.
	##
	## This is the primary mechanism where a user may take actions based on
	## data provided by the intelligence framework.
	global match: event(s: Seen, items: set[Item]);

	## This hook can be used to influence the logging of intelligence hits
	## (e.g. by adding data to the Info record). The default information is
	## added with a priority of 5.
	##
	## info: The Info record that will be logged.
	##
	## s: Information about the data seen.
	##
	## items: The intel items that match the seen data.
	##
	## In case the hook execution is terminated using break, the match will
	## not be logged.
	global extend_match: hook(info: Info, s: Seen, items: set[Item]);

	## The expiration timeout for intelligence items. Once an item expires, the
	## :bro:id:`Intel::item_expired` hook is called. Reinsertion of an item 
	## resets the timeout. A negative value disables expiration of intelligence 
	## items.
	const item_expiration = -1 min &redef;

	## This hook can be used to handle expiration of intelligence items.
	##
	## indicator: The indicator of the expired item.
	##
	## indicator_type: The indicator type of the expired item.
	##
	## metas: The set of metadata describing the expired item.
	##
	## If all hook handlers are executed, the expiration timeout will be reset.
	## Otherwise, if one of the handlers terminates using break, the item will
	## be removed.
	global item_expired: hook(indicator: string, indicator_type: Type, metas: set[MetaData]);

	global log_intel: event(rec: Info);
}

# Internal handler for matches with no metadata available.
global match_no_items: event(s: Seen);

# Internal events for cluster data distribution.
global new_item: event(item: Item);
global remove_item: event(item: Item, purge_indicator: bool);
global purge_item: event(item: Item);

# Optionally store metadata.  This is used internally depending on
# if this is a cluster deployment or not.
const have_full_data = T &redef;

# Table of metadata, indexed by source string.
type MetaDataTable: table[string] of MetaData;

# Expiration handlers.
global expire_host_data: function(data: table[addr] of MetaDataTable, idx: addr): interval;
global expire_subnet_data: function(data: table[subnet] of MetaDataTable, idx: subnet): interval;
global expire_string_data: function(data: table[string, Type] of MetaDataTable, idx: any): interval;

# The in memory data structure for holding intelligence.
type DataStore: record {
	host_data:    table[addr] of MetaDataTable &write_expire=item_expiration &expire_func=expire_host_data;
	subnet_data:  table[subnet] of MetaDataTable &write_expire=item_expiration &expire_func=expire_subnet_data;
	string_data:  table[string, Type] of MetaDataTable &write_expire=item_expiration &expire_func=expire_string_data;
};
global data_store: DataStore &redef;

# The in memory data structure for holding the barest matchable intelligence.
# This is primarily for workers to do the initial quick matches and store
# a minimal amount of data for the full match to happen on the manager.
type MinDataStore: record {
	host_data:    set[addr];
	subnet_data:  set[subnet];
	string_data:  set[string, Type];
};
global min_data_store: MinDataStore &redef;


event bro_init() &priority=5
	{
	Log::create_stream(LOG, [$columns=Info, $ev=log_intel, $path="intel"]);
	}

# Function that abstracts expiration of different types.
function expire_item(indicator: string, indicator_type: Type, metas: set[MetaData]): interval
	{
	if ( hook item_expired(indicator, indicator_type, metas) )
		return item_expiration;
	else
		remove([$indicator=indicator, $indicator_type=indicator_type, $meta=[$source=""]], T);
	return 0 sec;
	}

# Expiration handler definitions.
function expire_host_data(data: table[addr] of MetaDataTable, idx: addr): interval
	{
	local meta_tbl: MetaDataTable = data[idx];
	local metas: set[MetaData];
	for ( src in meta_tbl )
		add metas[meta_tbl[src]];

	return expire_item(cat(idx), ADDR, metas);
	}

function expire_subnet_data(data: table[subnet] of MetaDataTable, idx: subnet): interval
	{
	local meta_tbl: MetaDataTable = data[idx];
	local metas: set[MetaData];
	for ( src in meta_tbl )
		add metas[meta_tbl[src]];

	return expire_item(cat(idx), ADDR, metas);
	}

function expire_string_data(data: table[string, Type] of MetaDataTable, idx: any): interval
	{
	local indicator: string;
	local indicator_type: Type;
	[indicator, indicator_type] = idx;

	local meta_tbl: MetaDataTable = data[indicator, indicator_type];
	local metas: set[MetaData];
	for ( src in meta_tbl )
		add metas[meta_tbl[src]];

	return expire_item(indicator, indicator_type, metas);
	}

# Function to check for intelligence hits.
function find(s: Seen): bool
	{
	local ds = have_full_data ? data_store : min_data_store;

	if ( s?$host )
		{
		return ((s$host in ds$host_data) ||
		        (|matching_subnets(addr_to_subnet(s$host), ds$subnet_data)| > 0));
		}
	else
		{
		return ([to_lower(s$indicator), s$indicator_type] in ds$string_data);
		}
	}

# Function to retrieve intelligence items while abstracting from different
# data stores for different indicator types.
function get_items(s: Seen): set[Item]
	{
	local return_data: set[Item];
	local mt: MetaDataTable;

	if ( ! have_full_data )
		{
		Reporter::warning(fmt("Intel::get_items was called from a host (%s) that doesn't have the full data.",
			peer_description));
		return return_data;
		}

	if ( s?$host )
		{
		# See if the host is known about and it has meta values
		if ( s$host in data_store$host_data )
			{
			mt = data_store$host_data[s$host];
			for ( m in mt )
				{
				add return_data[Item($indicator=cat(s$host), $indicator_type=ADDR, $meta=mt[m])];
				}
			}
		# See if the host is part of a known subnet, which has meta values
		local nets: table[subnet] of MetaDataTable;
		nets = filter_subnet_table(addr_to_subnet(s$host), data_store$subnet_data);
		for ( n in nets )
			{
				mt = nets[n];
				for ( m in mt )
					{
					add return_data[Item($indicator=cat(n), $indicator_type=SUBNET, $meta=mt[m])];
					}
			}
		}
	else
		{
		local lower_indicator = to_lower(s$indicator);
		# See if the string is known about and it has meta values
		if ( [lower_indicator, s$indicator_type] in data_store$string_data )
			{
			mt = data_store$string_data[lower_indicator, s$indicator_type];
			for ( m in mt )
				{
				add return_data[Item($indicator=s$indicator, $indicator_type=s$indicator_type, $meta=mt[m])];
				}
			}
		}

	return return_data;
	}

function Intel::seen(s: Seen)
	{
	if ( find(s) )
		{
		if ( s?$host )
			{
			s$indicator = cat(s$host);
			s$indicator_type = Intel::ADDR;
			}

		if ( ! s?$node )
			{
			s$node = peer_description;
			}

		if ( have_full_data )
			{
			local items = get_items(s);
			event Intel::match(s, items);
			}
		else
			{
			event Intel::match_no_items(s);
			}
		}
	}

event Intel::match(s: Seen, items: set[Item]) &priority=5
	{
	local info = Info($ts=network_time(), $seen=s, $matched=TypeSet());

	if ( hook extend_match(info, s, items) )
		Log::write(Intel::LOG, info);
	}

hook extend_match(info: Info, s: Seen, items: set[Item]) &priority=5
	{
	# Add default information to matches.
	if ( s?$conn )
		{
		s$uid = s$conn$uid;
		info$id  = s$conn$id;
		}

	if ( s?$uid )
		info$uid = s$uid;

	for ( item in items )
		{
		add info$sources[item$meta$source];
		add info$matched[item$indicator_type];
		}
	}

function insert(item: Item)
	{
	# Create and fill out the metadata item.
	local meta = item$meta;
	local meta_tbl: table [string] of MetaData;
	local is_new: bool = T;

	# All intelligence is case insensitive at the moment.
	local lower_indicator = to_lower(item$indicator);

	if ( item$indicator_type == ADDR )
		{
		local host = to_addr(item$indicator);
		if ( have_full_data )
			{
			if ( host !in data_store$host_data )
				data_store$host_data[host] = table();
			else
				is_new = F;

			meta_tbl = data_store$host_data[host];
			}

		add min_data_store$host_data[host];
		}
	else if ( item$indicator_type == SUBNET )
		{
		local net = to_subnet(item$indicator);
		if ( have_full_data )
			{
			if ( !check_subnet(net, data_store$subnet_data) )
				data_store$subnet_data[net] = table();
			else
				is_new = F;

			meta_tbl = data_store$subnet_data[net];
			}

		add min_data_store$subnet_data[net];
		}
	else
		{
		if ( have_full_data )
			{
			if ( [lower_indicator, item$indicator_type] !in data_store$string_data )
				data_store$string_data[lower_indicator, item$indicator_type] = table();
			else
				is_new = F;

			meta_tbl = data_store$string_data[lower_indicator, item$indicator_type];
			}

		add min_data_store$string_data[lower_indicator, item$indicator_type];
		}

	if ( have_full_data )
		{
		# Insert new metadata or update if already present
		meta_tbl[meta$source] = meta;
		}

	if ( is_new )
		# Trigger insert for cluster in case the item is new
		# or insert was called on a worker
		event Intel::new_item(item);
	}

# Function to check whether an item is present.
function item_exists(item: Item): bool
	{
	local ds = have_full_data ? data_store : min_data_store;

	switch ( item$indicator_type )
		{
		case ADDR:
			return to_addr(item$indicator) in ds$host_data;
		case SUBNET:
			return to_subnet(item$indicator) in ds$subnet_data;
		default:
			return [item$indicator, item$indicator_type] in ds$string_data;
		}
	}

# Function to remove metadata of an item. The function returns T
# if there is no metadata left for the given indicator.
function remove_meta_data(item: Item): bool
	{
	if ( ! have_full_data )
		{
		Reporter::warning(fmt("Intel::remove_meta_data was called from a host (%s) that doesn't have the full data.",
			peer_description));
		return F;
		}

	switch ( item$indicator_type )
		{
		case ADDR:
			local host = to_addr(item$indicator);
			delete data_store$host_data[host][item$meta$source];
			return (|data_store$host_data[host]| == 0);
		case SUBNET:
			local net = to_subnet(item$indicator);
			delete data_store$subnet_data[net][item$meta$source];
			return (|data_store$subnet_data[net]| == 0);
		default:
			delete data_store$string_data[item$indicator, item$indicator_type][item$meta$source];
			return (|data_store$string_data[item$indicator, item$indicator_type]| == 0);
		}
	}

function remove(item: Item, purge_indicator: bool)
	{
	# Check whether the indicator is present
	if ( ! item_exists(item) )
		{
		Reporter::info(fmt("Tried to remove non-existing item '%s' (%s).",
			item$indicator, item$indicator_type));
		return;
		}

	# Delegate removal if we are on a worker
	if ( !have_full_data )
		{
		event Intel::remove_item(item, purge_indicator);
		return;
		}

	# Remove metadata from manager's data store
	local no_meta_data = remove_meta_data(item);
	# Remove whole indicator if necessary
	if ( no_meta_data || purge_indicator )
		{
		switch ( item$indicator_type )
			{
			case ADDR:
				local host = to_addr(item$indicator);
				delete data_store$host_data[host];
				break;
			case SUBNET:
				local net = to_subnet(item$indicator);
				delete data_store$subnet_data[net];
				break;
			default:
				delete data_store$string_data[item$indicator, item$indicator_type];
				break;
			}
		# Trigger deletion in minimal data stores
		event Intel::purge_item(item);
		}
	}

# Handling of indicator removal in minimal data stores.
event purge_item(item: Item)
	{
	switch ( item$indicator_type )
		{
		case ADDR:
			local host = to_addr(item$indicator);
			delete min_data_store$host_data[host];
			break;
		case SUBNET:
			local net = to_subnet(item$indicator);
			delete min_data_store$subnet_data[net];
			break;
		default:
			delete min_data_store$string_data[item$indicator, item$indicator_type];
			break;
		}
	}

