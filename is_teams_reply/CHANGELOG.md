# Changelog

## 0.2.0

Breaking, so a new RendererId. What is drawn is unchanged: the same
entries give the same bytes.

- What the renderer returns is a `RenderOutcome` (was `Drawn`): a
  `RenderedBody` (was `Body`) or a `RenderRefused` (was `Refusal`). The
  render runner turns it into the `Outcome` the `rendered` entry carries.
- The docs say render runner, not follower.

## 0.1.0

- `teamsReply`: a final reply drawn from the one `turn` entry holding a
  `ReplyText` node, as a Bot Framework message activity. Anything else is
  refused.
