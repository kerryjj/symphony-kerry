# Symphony (Kerry's Fork)

> **Note:** This is a fork of [openai/symphony](https://github.com/openai/symphony) for personal development and experimentation. It is not intended for public use or distribution.

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[Symphony demo video preview](.github/media/symphony-demo.mp4)

*In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level.*

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> [https://github.com/openai/symphony/blob/main/SPEC.md](https://github.com/openai/symphony/blob/main/SPEC.md)

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> [https://github.com/openai/symphony/blob/main/elixir/README.md](https://github.com/openai/symphony/blob/main/elixir/README.md)

---

## Syncing with Upstream

To pull in changes from the original [openai/symphony](https://github.com/openai/symphony) repo:

```bash
git fetch upstream && git merge upstream/main
```

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).