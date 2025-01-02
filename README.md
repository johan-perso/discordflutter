# DiscordFlutter

A dart package to interact with the Discord API for user-account and bot, compatible with Flutter app on any platform.

> [!WARNING]
> This library is mostly incomplete, support for bot has not even started yet, and user-account support is very limited. Accounts can be terminated by Discord without guarantee by this library. Use at your own risk.

> [!CAUTION]
> This library is not and will not be maintained, it cannot be used in production, and it is not recommended to use in any project. The code is published here as it was in August 2024 when the project was still active.

## Todo

- [ ] Create a queue for requests --> avoic getting rate limited
- [ ] Detect captcha, and handle them properly when logging in through user account
- [ ] Defining rich presence
- [ ] Send message
- [ ] Send message with attachment (creating a new util)
- [ ] List message in a conv, and load them progressively
- [ ] Parse user flags, and user status
- [x] Fetch user info with their id
- [x] List joined guilds, friends, conversations and activities of friends
- [x] Emit events when a channel (private conversation) is created/updated/deleted, when friends presences is updated, and when client is ready
- [x] Get current user info
- [x] Login and logout (destroy current client)
- [x] Use cache to avoid useless requests

## Licence

MIT © [Johan](https://johanstick.fr). Support this project via [Ko-Fi](https://ko-fi.com/johan_stickman) or [PayPal](https://paypal.me/moipastoii) if you want to help me 💙