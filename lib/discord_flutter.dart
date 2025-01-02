library discord_flutter;

/* SOURCES
- Unofficial Docs for User Account https://docs.discord.sex/topics/opcodes-and-status-codes#gateway
- Event Ready : not included here
- Event Ready Supplemental : not included here
*/

/* TODO
- Defining rich presence
- Send message
- Send message with attachment (util)
- List message in a conv, and load them progressively
- Parse user flags
*/

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:stash/stash_api.dart';
import 'package:stash_memory/stash_memory.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shortid/shortid.dart';

// import 'package:discord_flutter/utils/globals.dart' as globals;
import 'package:discord_flutter/utils/censor_string.dart';

class DiscordFlutter {
  int discordSnowflakeToTimestamp(String snowflake) {
    int id = int.parse(snowflake);
    String binary = id.toRadixString(2).padLeft(64, '0');
    String excerpt = binary.substring(0, 42);
    int decimal = int.parse(excerpt, radix: 2);
    int unixTimestamp = decimal + 1420070400000;
    return unixTimestamp;
  }

  var client = {};

  final StreamController _messageController = StreamController.broadcast();
  Stream get onMessage => _messageController.stream;

  late WebSocketChannel gateway;

  bool cacheInitialized = false;
  late MemoryCacheStore _store;
  late Cache _cache;

  Future login(String token) async {
    if (client['ready'] == true) {
      throw Exception('Client is already initialized');
    }

    // check if store is initialized
    if (cacheInitialized == false) {
      cacheInitialized = true;
      _store = await newMemoryCacheStore();
      _cache = await _store.cache(
        maxEntries: 400,
        expiryPolicy: const CreatedExpiryPolicy(Duration(minutes: 5)),
      );
    }

    _messageController.add({ 'type': 'debug', 'message': 'Fetching Discord API to get the WebSocket URL' });
    final http.Response gatewayLink;
    try {
      gatewayLink = await http.get(Uri.parse('https://discord.com/api/v9/gateway'));
    } catch (e) {
      _messageController.add({ 'type': 'error', 'message': 'Failed to fetch Discord API (getting WebSocket URL): $e' });
      throw Exception('Failed to fetch Discord API (getting WebSocket URL): $e');
    }
    final Uri gatewayUrl;
    try {
      final gatewayData = gatewayLink.body;
      gatewayUrl = Uri.parse(jsonDecode(gatewayData)['url'] + '/?encoding=json&v=9');
    } catch (e) {
      _messageController.add({ 'type': 'error', 'message': 'Failed to parse Discord API response (getting WebSocket URL): $e' });
      throw Exception('Failed to parse Discord API response (getting WebSocket URL): $e');
    }

    // add things to client
    client['presenceDelays_timers'] = {};
    client['presenceDelays_ids'] = {};

    _messageController.add({ 'type': 'debug', 'message': 'Attempting to connect to $gatewayUrl' });

    gateway = WebSocketChannel.connect(gatewayUrl);
    await gateway.ready;

    int? lastHeartbeatAck;
    bool isSendingHeartbeat = false;
    int? lastSequenceNumber;

    gateway.stream.listen((message) async {
      // send to message controller
      _messageController.add({ 'type': 'socket-debug', 'message': message.toString() });

      // parse json message
      final decodedMessage = jsonDecode(message);
      if (decodedMessage['s'] != null) {
        lastSequenceNumber = decodedMessage['s'];
      }

      // op 10 (hello)
      if (decodedMessage['op'] == 10 && !isSendingHeartbeat) {
        // get heartbeat interval
        isSendingHeartbeat = true;
        final double heartbeatInterval = decodedMessage['d']['heartbeat_interval'].toDouble();
        _messageController.add({ 'type': 'socket-debug', 'message': '(will send heartbeat every $heartbeatInterval ms' });

        // start sending heartbeats
        Timer.periodic(Duration(milliseconds: (heartbeatInterval - 500).toInt()), (timer) {
          if (client['ready'] != true) {
            timer.cancel();
            return;
          }

          gateway.sink.add(jsonEncode({
            "op": 1,
            "d": lastSequenceNumber
          }));

          _messageController.add({ 'type': 'socket-debug', 'message': '(sent heartbeat, by interval)' });
        });

        // check if we receive heartbeats ack
        Timer.periodic(Duration(milliseconds: (heartbeatInterval * 1.5).toInt()), (timer) {
          if (client['ready'] != true) {
            timer.cancel();
            return;
          }

          if (lastHeartbeatAck == null || DateTime.now().millisecondsSinceEpoch - lastHeartbeatAck! > heartbeatInterval * 1.5) {
            _messageController.add({ 'type': 'socket-error', 'message': 'Heartbeat ack not received in time, destroying connection' });
            destroy(ignoreError: true);
            timer.cancel();
          }
        });

        // save token in client properties
        client['token'] = token;

        // send identify event (login)
        _messageController.add({'type': 'debug', 'message': 'Attempting to login with token: ${censorString(token)}'});
        gateway.sink.add(jsonEncode({
          "op": 2,
          "d": {
            "token": token,
            "capabilities": 16383, // hardcoded, obtained from the Discord Android app, idk what it is
            "client_state": {"guild_versions":{}},
            // "presence": {
            //   "activities": [{
            //     "name": "Apple Music",
            //     "details": "Rap catéchisme",
            //     "state": "Freeze Corleone feat. Alpha Wann",
            //     "type": 2 // https://discord.com/developers/docs/topics/gateway-events#activity-object-activity-types
            //     // to add assets (album cover for ex) : https://github.com/aiko-chan-ai/discord.js-selfbot-v13/blob/main/src/structures/Presence.js#L939 ; https://github.com/JustYuuto/deezer-discord-rpc/blob/master/src/utils/Activity.ts
            //     // we can add a third text (album name) only if we add a large image
            //   }],
            //   "afk": false,
            //   "status": "online",
            //   "since": (DateTime.now().millisecondsSinceEpoch / 1000).floor(),
            // }, // TODO: delete this chunk of code, it will not be used // we will create a method to manually set presence after initial connection (opcode 3, Presence Update) : https://docs.discord.sex/topics/gateway-events#update-presence ; https://discord.com/developers/docs/topics/gateway-events#update-presence-example-gateway-presence-update
            "properties": { // obtained from the Discord Android app on a Pixel 6a, we will let theses datas hardcoded in case Discord implements verification of properties
              "os": "Android", // it's this property that makes Discord know we're on mobile
              "browser": "Discord Android",
              "device": "bluejay",
              "system_locale": "fr-FR",
              "client_version": "224.17 - rn",
              "release_channel": "betaRelease",
              "device_vendor_id": "", // a uuid, idk if it would reveal something so I let it empty ig
              "browser_user_agent": "",
              "browser_version": "",
              "os_version": "34", // = Android 14
              "client_build_number": 224117,
              "client_event_source": null
            }
          }
        }));

        // frequently send presences arrivals
        client['presenceArrivalsTimer'] = Timer.periodic(const Duration(seconds: 5), (timer) {
          if (client['ready'] != true) return; // check if client is ready
          _messageController.add({ 'type': 'socket-debug', 'message': '(verifying presences updates)' });

          // if no old presence, save the current one and loop on
          if (client['users_presence_old'] == null) {
            client['users_presence_old'] = (client['temp_users_presence'] ?? []).toList();
            _messageController.add({ 'type': 'socket-debug', 'message': '(no old presence, will try again)' });
            return;
          }

          // check if there is presences have changed (new, updated, or removed)
          bool hasChanged = false;
          for (var i = 0; i < client['temp_users_presence'].length; i++) {
            if (!client['users_presence_old'].contains(client['temp_users_presence'][i])) {
              hasChanged = true;
              break;
            }
          }
          for (var i = 0; i < client['users_presence_old'].length; i++) {
            if (!client['temp_users_presence'].contains(client['users_presence_old'][i])) {
              hasChanged = true;
              break;
            }
          }

          // if changes, send an event
          if (hasChanged) {
            client['users_presence_old'] = client['temp_users_presence'].toList();
            client['users_presence'] = client['temp_users_presence'].toList();
            _messageController.add({ 'type': 'socket-debug', 'message': '(presences have changed)' });
            _messageController.add({ 'type': 'socket-arrival', 'message': 'PRESENCE_UPDATE' });
          }

          // if no changes, loop on
          else {
            _messageController.add({ 'type': 'socket-debug', 'message': '(no changes in presences)' });
          }
        });
      }

      // op 1, send a heartbeat manually
      else if (decodedMessage['op'] == 1) {
        gateway.sink.add(jsonEncode({
          "op": 1,
          "d": lastSequenceNumber
        }));

        _messageController.add({ 'type': 'socket-debug', 'message': '(sent heartbeat, asked by discord)' });
      }

      // op 7 / 9 (reconnect / invalid session)
      else if (decodedMessage['op'] == 7 || decodedMessage['op'] == 9) {
        _messageController.add({ 'type': 'socket-error', 'message': 'Gateway asked us to destroy the connection' });
        destroy(ignoreError: true);
      }

      // op 11 (heartbeat ack)
      else if (decodedMessage['op'] == 11) {
        _messageController.add({ 'type': 'socket-debug', 'message': '(received heartbeat ack)' });
        lastHeartbeatAck = DateTime.now().millisecondsSinceEpoch;
      }

      // op 0 (dispatch)
      else if (decodedMessage['op'] == 0) {
        // ready
        if (decodedMessage['t'] == 'READY') {
          // save some infos
          client['user'] = decodedMessage['d']['user'];
          client['guilds'] = decodedMessage['d']['guilds'];
          client['connected_accounts'] = decodedMessage['d']['connected_accounts'];
          client['user_guild_settings'] = decodedMessage['d']['user_guild_settings'];
          client['sessions'] = decodedMessage['d']['sessions'];
          client['read_state'] = decodedMessage['d']['read_state'];
          client['friend_suggestion_count'] = decodedMessage['d']['friend_suggestion_count'];
          client['country_code'] = decodedMessage['d']['country_code'];

          // add users to cache
          List<Map<String, dynamic>> users = decodedMessage['d']['users'].cast<Map<String, dynamic>>();
          for (var i = 0; i < users.length; i++) {
            users[i]['partials'] = 'base';
            await _cache.put('user:${users[i]['id']}', users[i]);
          }

          // save relationships (friends, requests, blocked)
          List<Map<String, dynamic>> relationships = decodedMessage['d']['relationships'].cast<Map<String, dynamic>>();
          relationships.sort((a, b) => (a['type'] as int).compareTo(b['type'] as int)); // sort relationships
          for (var i = 0; i < relationships.length; i++) { // add user data to relationships
            var user = decodedMessage['d']['users'].firstWhere((user) => user['id'] == relationships[i]['id']); // avoid fetching user, it would make too many requests
            user['partials'] = 'base';
            user['user'] = user; // add user to user object, to be similar to the response of the getUser method
            relationships[i]['user'] = user;
          }
          client['relationships'] = relationships; // save relationships

          // save recents dms convs
          List dmsParsed = [];
          List<Map<String, dynamic>> dms = decodedMessage['d']['private_channels'].cast<Map<String, dynamic>>();

          // sort dms by last message timestamp (sometimes they aren't there ; isn't perfect order like on discord but whatever)
          dms.sort((a, b) {
            // get timestamp from last message id
            int aTimestamp = a['last_message_id'] != null ? discordSnowflakeToTimestamp(a['last_message_id']) : 0;
            int bTimestamp = b['last_message_id'] != null ? discordSnowflakeToTimestamp(b['last_message_id']) : 0;

            // if no timestamp, get from friend since
            if (aTimestamp == 0 && a['type'] == 1 && a['recipient_ids'].length > 0) {
              try {
                var aRelationship = relationships.firstWhere((relationship) => relationship['id'] == a['recipient_ids'][0]);
                aTimestamp = aRelationship['since'] != null ? DateTime.parse(aRelationship['since']).millisecondsSinceEpoch : 0;
              } catch (e) {
                // maybe no relationship found
              }
            }
            if (bTimestamp == 0 && b['type'] == 1 && b['recipient_ids'].length > 0) {
              try {
                var bRelationship = relationships.firstWhere((relationship) => relationship['id'] == b['recipient_ids'][0]);
                bTimestamp = bRelationship['since'] != null ? DateTime.parse(bRelationship['since']).millisecondsSinceEpoch : 0;
              } catch (e) {
                // maybe no relationship found
              }
            }

            // compare
            return bTimestamp.compareTo(aTimestamp);
          });

          for (var i = 0; i < dms.length; i++) { // add users datas to all convs
            var recipientIds = dms[i]['recipient_ids'] ?? [];
            dms[i]['recipients_users'] = [];
            for (var recipient in recipientIds) {
              var user = decodedMessage['d']['users'].firstWhere((user) => user['id'] == recipient); // avoid fetching user, it would make too many requests
              user['partials'] = 'base';
              user['user'] = user; // add user to user object, to be similar to the response of the getUser method
              dms[i]['recipients_users'].add(decodedMessage['d']['users'].firstWhere((user) => user['id'] == recipient));
            }
          }

          for (var i = 0; i < dms.length; i++) { // add specific data to all convs
            var dm = dms[i];
            dmsParsed.add({
              'channel_id': dm['channel_id'] ?? dm['id'],
              'type': dm['type'],
              'name': dm['name'],
              'icon': dm['icon'],
              'recipient_ids': dm['recipient_ids'],
              'recipients_users': dm['recipients_users'],
            });
          }

          client['dms'] = dmsParsed; // save dms

          // send infos to message controller
          client['ready'] = true;
          _messageController.add({ 'type': 'debug', 'message': 'Logged in as ${client['user']['username']}${client['user']['discriminator'] == '0' ? '' : client['user']['discriminator']}' });
          _messageController.add({ 'type': 'socket-arrival', 'message': 'READY' });
        }

        // ready supplemental
        else if (decodedMessage['t'] == 'READY_SUPPLEMENTAL') {
          // Prepare users presences variables
          List usersPresence = [];
          List usersIdsPresences = [];
          Map mergedPresences = decodedMessage['d']['merged_presences']; // guilds (array of arrays), friends (array of objects)

          // Avoid adding multiple times the same user presence and check if user isn't offline
          for (var guild in mergedPresences['guilds']) {
            for (var presence in guild) {
              if (presence['status'] == 'offline') continue;

              if (!usersIdsPresences.contains(presence['user_id'])) {
                usersIdsPresences.add(presence['user_id']);
                usersPresence.add({
                  "user": await getUser(presence['user_id'], force: true),
                  "status": presence['status'],
                  "client_status": presence['client_status'],
                  "activities": presence['activities']
                });
              }
            }
          }
          for (var presence in mergedPresences['friends']) {
            if (presence['status'] == 'offline') continue;

            if (!usersIdsPresences.contains(presence['user_id'])) {
              usersIdsPresences.add(presence['user_id']);
              usersPresence.add({
                "user": await getUser(presence['user_id'], force: true),
                "status": presence['status'],
                "client_status": presence['client_status'],
                "activities": presence['activities']
              });
            }
          }

          // Add user data to presences
          for (var i = 0; i < usersPresence.length; i++) {
            if (usersPresence[i]['user']['user']['bot'] == true) {
              usersPresence.removeAt(i);
              i--;
            }
          }

          client['temp_users_presence'] = usersPresence.toList();
          client['users_presence'] = usersPresence.toList();
          _messageController.add({ 'type': 'socket-arrival', 'message': 'PRESENCE_UPDATE' });
        }

        // presence of someone is updated
        else if (decodedMessage['t'] == 'PRESENCE_UPDATE') {
          // get the new presence
          var newPresenceNotFormatted = decodedMessage['d'];
          String userId = newPresenceNotFormatted['user']['id'];

          // if we already have a timer for this user, we will cancel it
          try {
            await client['presenceDelays_timers'][userId].cancel();
          } catch (e) {
            // no timer found
          }

          // create timer (this will avoid receiving multiple presences in a short interval)
          String randomId = shortid.generate();
          client['presenceDelays_ids'][userId] = randomId; // save a unique id to double-check
          client['presenceDelays_timers'][userId] = Timer(const Duration(seconds: 5), () async {
            // check timer id
            if (client['presenceDelays_ids'] == null) return;
            if (client['presenceDelays_ids'][userId] != randomId) return;

            // format presence object
            Map newPresence = {
              "user": await getUser(userId, force: true),
              "status": newPresenceNotFormatted['status'],
              "client_status": newPresenceNotFormatted['client_status'],
              "activities": newPresenceNotFormatted['activities']
            };

            // get the old presence
            late dynamic oldPresence;
            try {
              oldPresence = client['temp_users_presence'].firstWhere((presence) => presence['user']['user']['id'] == userId);
            } catch (e) {
              _messageController.add({ 'type': 'socket-debug', 'message': '($userId didn\'t had presence)' });
              oldPresence = null;
            }

            // if user is now offline
            if (newPresence['status'] == 'offline') {
              _messageController.add({ 'type': 'socket-debug', 'message': '(removing presence for $userId)' });
              if(oldPresence != null) await client['temp_users_presence'].remove(oldPresence);
            }

            // if user was online and is still online
            else if (oldPresence != null && oldPresence['status'] != 'offline' && newPresence['status'] != 'offline') {
              _messageController.add({ 'type': 'socket-debug', 'message': '(replacing current presence for $userId)' });
              int index = client['temp_users_presence'].indexOf(oldPresence);
              await client['temp_users_presence'].removeAt(index);
              await client['temp_users_presence'].insert(index, newPresence);
            }

            // if user was offline and is now online
            else if (oldPresence == null || oldPresence['status'] == 'offline') {
              _messageController.add({ 'type': 'socket-debug', 'message': '(adding presence for $userId)' });
              await client['temp_users_presence'].add(newPresence);
            }
          });
        }

        // channel created (joined a group for example)
        // TODO: ensure it only includes private conv, and not channel on a server
        else if (decodedMessage['t'] == 'CHANNEL_CREATE') {
          // get the channel
          var channel = decodedMessage['d'];
          var channelType = channel['type'];

          // if it's a private channel, we will add/update pos the user to the dms list
          if(channelType == 1) {
            // get the dm channel
            var dmChannel = client['dms'].firstWhere((dm) => dm['channel_id'] == channel['id'], orElse: () => null);

            // if the dm channel isn't in the dms list, we will add it at the top
            if(dmChannel == null) {
              // get the user
              var user = await getUser(channel['recipients'][0]['id'], force: true);

              // add the dm channel to the dms list
              client['dms'].insert(0, {
                'channel_id': channel['id'],
                'type': 1,
                'name': user['username'],
                'recipient_ids': [channel['recipients'][0]['id']],
                'recipients_users': [user]
              });
            }

            // send to controller
            _messageController.add({ 'type': 'socket-arrival', 'message': 'DMS_CREATE' });
          }

          // if it's a group channel
          else if(channelType == 3) {
            // get the group channel
            var groupChannel = client['dms'].firstWhere((dm) => dm['channel_id'] == channel['id'], orElse: () => null);

            // if the group channel isn't in the dms list, we will add it at the top
            if(groupChannel == null) {
              // add the group channel to the dms list
              client['dms'].insert(0, {
                'channel_id': channel['id'],
                'type': 3,
                'name': channel['name'],
                'recipient_ids': channel['recipients'].map((recipient) => recipient['id']).toList(),
                'recipients_users': channel['recipients']
              });
            }

            // send to controller
            _messageController.add({ 'type': 'socket-arrival', 'message': 'DMS_CREATE' });
          }
        }

        // channel deleted
        // {"t":"CHANNEL_DELETE","s":18,"op":0,"d":{"type":3,"owner_id":"x","name":"test","last_message_id":"x","id":"x","icon":null,"flags":0}}
        // TODO: ensure it only includes private conv deletion (leave/kick group), and not channel deleted on a server
        else if (decodedMessage['t'] == 'CHANNEL_DELETE') {
          // get the channel
          var channel = decodedMessage['d'];
          var channelType = channel['type'];

          // if it's a private or group channel, we will remove it from the dms list
          if(channelType == 1 || channelType == 3) {
            // get the dm channel
            var dmChannel = client['dms'].firstWhere((dm) => dm['channel_id'] == channel['id'], orElse: () => null);

            // if the dm channel is in the dms list, we will remove it
            if(dmChannel != null) {
              client['dms'].remove(dmChannel);
            }

            // send to controller
            _messageController.add({ 'type': 'socket-arrival', 'message': 'DMS_DELETE' });
          }
        }

        // message received
        else if (decodedMessage['t'] == 'MESSAGE_CREATE') {
          // get author id, and determine if it's a dm or a guild message
          var guildId = decodedMessage['d']['guild_id'];
          var channelType = guildId == null ? 'private' : 'guild';

          // if it's a private dm, we will add/update pos the user to the dms list
          if(channelType == 'private') {
            // get the dm channel
            var dmChannel = client['dms'].firstWhere((dm) => dm['channel_id'] == decodedMessage['d']['channel_id'], orElse: () => null);

            // if the dm channel is in the dms list, we will move it at the top
            if(dmChannel != null) {
              // add the dm channel to the dms list at the top and remove the old one
              var dmChannelIndex = client['dms'].indexOf(dmChannel);
              client['dms'].insert(0, dmChannel);
              client['dms'].removeAt(dmChannelIndex + 1);
            }

            // if the dm channel isn't in the dms list, we will add it at the top
            // Removed because we should already handle that with CHANNEL_CREATE event
            // else {
              // // get the user
              // var authorId = decodedMessage['d']['author']['id'];
              // var user = await getUser(authorId, force: true);

              // // add the dm channel to the dms list
              // client['dms'].insert(0, {
              //   'channel_id': decodedMessage['d']['channel_id'] ?? decodedMessage['d']['id'],
              //   'type': 1,
              //   'name': user['username'],
              //   'recipient_ids': [authorId],
              //   'recipients_users': [user]
              // });
            // }

          // send to controller
          _messageController.add({ 'type': 'socket-arrival', 'message': 'DMS_UPDATE' });

          // TODO: send to controller, determine if it's a guild
          }
        }
      }

      // TODO: send other important events to message controller with clean messages like discordjs (typing etc)
    });

    gateway.stream.handleError((error) {
      _messageController.add({ 'type': 'socket-error', 'message': 'WebSocket connection error: $error' });
      destroy();
    });

    return true;
  }

  Future destroy({ bool ignoreError = false }) async {
    if (!ignoreError && client['ready'] != true) {
      throw Exception('Client is not yet initialized');
    }

    _messageController.add({'type': 'debug', 'message': 'Ending gateway connection'});
    await gateway.sink.close();

    _messageController.add({'type': 'debug', 'message': 'Clearing timers'});
    client['presenceArrivalsTimer'].cancel();

    _messageController.add({'type': 'debug', 'message': 'Clearing cache'});
    await _cache.clear();

    _messageController.add({'type': 'debug', 'message': 'Destroying client'});
    client = {};

    _messageController.add({'type': 'debug', 'message': 'Successfully destroyed client'});
    return true;
  }

  Future getUser(String userId, { bool returnUser = false, bool force = false }) async { // force = true : accept to fetch even if client isn't ready
    if (client['ready'] != true && !force) {
      throw Exception('Client is not yet initialized');
    }

    // check from cache
    _messageController.add({ 'type': 'debug', 'message': 'Checking if user $userId is cached' });
    final cachedUser = await _cache.get('user:$userId');
    if (cachedUser != null) {
      var cachedUserMethod = cachedUser['partials'];

      if (cachedUserMethod.runtimeType == String && cachedUserMethod == 'base') {
        _messageController.add({ 'type': 'debug', 'message': 'User $userId was found in cache with limited infos, assuming it wasn\'t in cache' });
      } else {
        _messageController.add({ 'type': 'debug', 'message': 'User $userId was found in cache with infos, returning it' });
        return cachedUser;
      }
    }

    // if no token provided
    if (client['token'] == null) {
      _messageController.add({ 'type': 'error', 'message': 'No token provided, can\'t fetch user $userId' });
      throw Exception('No token provided, can\'t fetch user $userId');
    }

    // fetch base infos and parse them
    _messageController.add({ 'type': 'debug', 'message': 'User $userId wasn\'t cached, fetching API (base infos)' });
    final http.Response userBaseResponse = await http.get(Uri.parse('https://discord.com/api/v9/users/$userId'), headers: {
      'Authorization': client['token'],
      'X-Discord-Locale': 'en-US'
    });
    _messageController.add({ 'type': 'debug', 'message': 'Decoding and parsing response' });
    final userBase = jsonDecode(userBaseResponse.body);
    if (userBase['message'] != null) {
      _messageController.add({ 'type': 'error', 'message': 'Failed to fetch user $userId: ${userBase['message']}' });
      throw Exception('Failed to fetch user $userId: ${userBase['message']}');
    }
    _messageController.add({ 'type': 'debug', 'message': 'Base user $userId fetched successfully' });

    // fetch profile (more infos about user but may fail if not friend or not in mutual server)
    _messageController.add({ 'type': 'debug', 'message': 'Fetching API (profile infos)' });
    final http.Response userProfileResponse = await http.get(Uri.parse('https://discord.com/api/v9/users/$userId/profile'), headers: {
      'Authorization': client['token'],
      'X-Discord-Locale': 'en-US'
    });
    _messageController.add({ 'type': 'debug', 'message': 'Decoding and parsing response' });
    final userProfile = jsonDecode(userProfileResponse.body);
    if (userProfile['message'] != null) {
      _messageController.add({ 'type': 'debug', 'message': 'Failed to fetch user $userId profile: ${userProfile['message']}' });
    } else {
      _messageController.add({ 'type': 'debug', 'message': 'Profile user $userId fetched successfully' });
    }

    // merge both infos
    Map mergedUser = {};
    if (userProfile['message'] != null) {
      mergedUser = { user: userBase };
      mergedUser['partials'] = 'profile_not_found';
    } else {
      mergedUser = userProfile;
      mergedUser['partials'] = 'include_profile';
    }

    await _cache.put('user:$userId', mergedUser);
    _messageController.add({ 'type': 'debug', 'message': 'User $userId infos saved in cache' });

    if (returnUser) {
      return mergedUser['user'];
    } else {
      return mergedUser;
    }
  }

  String getAvatarUrl({ String type = 'user', Map user = const {}, String? id, String? hash, int size = 128 }) {
    if ((!user.containsKey('avatar') || user['avatar'] == null) && (hash == null || id == null)) return 'https://cdn.discordapp.com/embed/avatars/0.png';

    String userHash = user['avatar'] ?? hash ?? '0';

    if (userHash.startsWith('a_')) {
      return 'https://cdn.discordapp.com/${type == 'user' ? 'avatars' : type == 'channel' ? 'channel-icons': 'unknown'}/${id ?? user['id'] ?? 0}/$userHash.gif?size=$size';
    } else {
      return 'https://cdn.discordapp.com/${type == 'user' ? 'avatars' : type == 'channel' ? 'channel-icons': 'unknown'}/${id ?? user['id'] ?? 0}/$userHash.png?size=$size';
    }
  }

  String getConnectionLink(Map connection) { // some types doesn't return anything, the client should have to handle it
    switch (connection['type']) {
      case 'github':
        return 'https://github.com/${connection['name']}';
      case 'instagram':
        return 'https://instagram.com/${connection['name']}';
      case 'reddit':
        return 'https://reddit.com/u/${connection['name']}';
      case 'spotify':
        return 'https://open.spotify.com/user/${connection['id']}';
      case 'steam':
        return 'https://steamcommunity.com/profiles/${connection['id']}';
      case 'tiktok':
        return 'https://tiktok.com/@${connection['name']}';
      case 'twitch':
        return 'https://twitch.tv/${connection['name']}';
      case 'twitter':
        return 'https://twitter.com/${connection['name']}';
      case 'ebay':
        return 'https://ebay.com/usr/${connection['name']}';
      case 'domain':
        return 'https://${connection['name']}';
      case 'youtube':
        return 'https://youtube.com/channel/${connection['id']}';
    }

    return '';

    /* paypal: (discord doesn't include any link)
    "type": "paypal",
    "id": "......",
    "name": ".......",
    "verified": true,
    "metadata": {
        "verified": "0",
        "created_at": "2017-12-17T00:00:00+00:00"
    }
    */
  }

  Map get user => client['user'] ?? {};
  List get relationships => client['relationships'] ?? [];
  List get dms => client['dms'] ?? [];
  List get guilds => client['guilds'] ?? [];
  List get connectedAccounts => client['connected_accounts'] ?? [];
  late Map userGuildSettings = client['user_guild_settings'];
  late List sessions = client['sessions'];
  late Map readState = client['read_state'];
  // late final int friendSuggestionCount = client['friend_suggestion_count']; // not used
  late final String countryCode = client['country_code'];
  List get usersPresence => client['users_presence'] ?? [];

  final relationshipsType = {
    0: 'none', // No relationship exists (shouldn't usually be encountered)
    1: 'friend', // The user is a friend
    2: 'blocked', // The user is blocked
    3: 'incoming_request', // The user has sent a friend request to the current user
    4: 'outgoing_request', // The current user has sent a friend request to the user
    5: 'implicit' // The user is an affinity of the current user
  };

  final dmChannelsType = {
    1: 'private', // A private message
    3: 'group' // A group conversation
  };

  final usersStatus = {
    'online': 'Online',
    'offline': 'Offline',
    'idle': 'Idle',
    'dnd': 'Do not disturb',
    'invisible': 'Invisible'
  };

  final activitiesType = {
    0: 'Playing',
    1: 'Streaming',
    2: 'Listening to',
    3: 'Watching',
    4: 'Custom Status',
    5: 'Competing'
  };
}
