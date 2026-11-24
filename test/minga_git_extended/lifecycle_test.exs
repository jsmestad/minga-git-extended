defmodule MingaGitExtended.LifecycleTest do
  @moduledoc """
  Lifecycle coverage for GitExtended's source-owned registration.
  """

  # Exercises the global native sidebar registry and extension module reloads.
  use ExUnit.Case, async: false

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CodeLease
  alias Minga.Extension.InstanceRegistry
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.RuntimeSupervisor
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap.Active, as: ActiveKeymap
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.KeyParser
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Extension.RepositoryJob
  alias MingaEditor.Extension.Sidebar
  alias MingaGitExtended.Effects.CommitMessageGeneration
  alias MingaGitExtended.Effects.RemoteOperation
  alias MingaGitExtended.Test.EffectDependencies, as: Dependencies

  @source {:extension, :minga_git_extended}
  @other_source {:extension, :unrelated_extension}
  @admission Module.concat(__MODULE__, Admission)
  @timeout 2_000

  setup do
    Dependencies.reset(self())
    start_supervised!({CodeLease, name: @admission})

    :ok =
      CodeLease.activate_source(
        @source,
        [RemoteOperation, CommitMessageGeneration],
        server: @admission
      )

    cleanup_git_extended_contributions()

    on_exit(fn ->
      cleanup_git_extended_contributions()
    end)

    :ok
  end

  test "registers editor actions while the extension is enabled" do
    assert MingaGitExtended.__editor_event_handler_schema__() == [
             {MingaGitExtended.Commands, [:editor_action], []}
           ]
  end

  test "disable cancels only GitExtended work before runtime termination and rejects late delivery" do
    ctx = start_lifecycle_context()
    runtime = start_git_extended!(ctx)
    {scheduler, _task_supervisor} = start_scheduler()

    Dependencies.put({:remote, :push}, {:block, :ok})
    Dependencies.put({:remote, :pull}, {:block, :ok})

    activate_job_source(@source, [RemoteOperation])
    activate_job_source(@other_source, [RemoteOperation])

    state = %MingaEditor.State{
      workspace: %MingaEditor.Session.State{},
      effect_scheduler: scheduler
    }

    git_request = start_remote(state, @source, "/tmp/git-owned", :push)
    unrelated_request = start_remote(state, @other_source, "/tmp/unrelated", :pull)

    assert_receive {:dependency_called, {:remote, :push}, git_worker, "/tmp/git-owned"}, @timeout

    assert_receive {:dependency_called, {:remote, :pull}, unrelated_worker, "/tmp/unrelated"},
                   @timeout

    git_worker_monitor = Process.monitor(git_worker)
    unrelated_worker_monitor = Process.monitor(unrelated_worker)
    runtime_monitor = Process.monitor(runtime)

    task_ref = running_task_ref(scheduler, git_request.id)
    stop_git_extended!(ctx, callbacks(scheduler))

    assert_receive {:DOWN, ^git_worker_monitor, :process, ^git_worker, _reason}, @timeout
    assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}, @timeout
    refute EffectScheduler.active_source?(scheduler, @source)
    assert EffectScheduler.active_source?(scheduler, @other_source)
    refute_received {:DOWN, ^unrelated_worker_monitor, :process, ^unrelated_worker, _reason}

    assert_receive {:effect_terminal,
                    %Outcome{
                      value: {:canceled, :source_canceled},
                      request: %{id: git_request_id}
                    }},
                   @timeout

    assert git_request_id == git_request.id

    send(scheduler, {task_ref, {:ok, :late}})
    send(scheduler, {:effect_timeout, git_request.id})
    _barrier = EffectScheduler.stats(scheduler)
    refute_received {:effect_result, ^scheduler, %Outcome{request: %{id: ^git_request_id}}}

    send(unrelated_worker, {:release_dependency, {:remote, :pull}})
    unrelated_outcome = receive_candidate(scheduler, unrelated_request.id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, unrelated_outcome)
    EffectScheduler.finalize(scheduler, unrelated_outcome)
    _barrier = EffectScheduler.stats(scheduler)

    assert_receive {:DOWN, ^unrelated_worker_monitor, :process, ^unrelated_worker, :normal},
                   @timeout
  end

  defp activate_job_source(source, modules) do
    :ok = CodeLease.activate_source(source, modules)

    on_exit(fn ->
      {:ok, token} = CodeLease.quiesce_source(source)
      :ok = CodeLease.complete_unload(token)
    end)
  end

  defp start_remote(state, source, root, op) do
    assert {:ok, {:schedule, ^state, job}} =
             CallbackInvoker.invoke(
               source,
               RemoteOperation,
               :propose,
               [state, root, op, Dependencies],
               :command
             )

    RepositoryJob.submit(state, source, job)

    assert_receive {:effect_lifecycle,
                    %Outcome{value: :running, request: %{source: ^source} = request}},
                   @timeout

    request
  end

  test "disable terminalizes a pending commit result before extension code is removed" do
    ctx = start_lifecycle_context()
    _runtime = start_git_extended!(ctx)
    {scheduler, _task_supervisor} = start_scheduler()

    activate_job_source(@source, [CommitMessageGeneration])

    state = %MingaEditor.State{
      workspace: %MingaEditor.Session.State{},
      effect_scheduler: scheduler
    }

    assert {:ok, {:schedule, ^state, proposal}} =
             CallbackInvoker.invoke(
               @source,
               CommitMessageGeneration,
               :propose,
               [state, "/tmp/repo", {Dependencies, Dependencies}],
               :command
             )

    RepositoryJob.submit(state, @source, proposal)

    assert_receive {:effect_result, ^scheduler, %Outcome{value: {:completed, _}} = delayed},
                   @timeout

    request = delayed.request
    assert EffectScheduler.active_source?(scheduler, @source)

    stop_git_extended!(ctx, callbacks(scheduler))

    assert_receive {:effect_terminal,
                    %Outcome{
                      value: {:canceled, :source_canceled},
                      request: %{id: request_id}
                    }},
                   @timeout

    assert request_id == request.id
    assert EffectScheduler.claim(scheduler, delayed) == {:error, :not_pending}
    refute EffectScheduler.active_source?(scheduler, @source)
  end

  test "reload terminates the old child and replaces source-owned contributions without duplicates" do
    ctx = start_lifecycle_context()

    first_pid = start_git_extended!(ctx)
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx)) == {:ok, first_pid}
    assert_git_extended_contributions_registered(ctx)
    assert {:ok, admitted} = ArtifactAdmission.source_modules(@source)
    assert MingaGitExtended in admitted
    assert MingaGitExtended.Commands in admitted
    assert :code.is_loaded(MingaGitExtended) != false

    ref = Process.monitor(first_pid)
    stop_git_extended!(ctx)
    assert_receive {:DOWN, ^ref, :process, ^first_pid, _reason}, 1_000
    assert_git_extended_contributions_removed(ctx)

    second_pid = start_git_extended!(ctx)
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx)) == {:ok, second_pid}
    assert second_pid != first_pid
    assert_git_extended_contributions_registered(ctx)

    second_ref = Process.monitor(second_pid)
    stop_git_extended!(ctx)
    assert_receive {:DOWN, ^second_ref, :process, ^second_pid, _reason}, 1_000
    assert_git_extended_contributions_removed(ctx)
  end

  defp start_lifecycle_context do
    expose_source_only!()

    supervisor = start_supervised!({ExtSupervisor, name: unique_name("git_extended_ext_sup")})
    registry = start_supervised!({ExtRegistry, name: unique_name("git_extended_ext_registry")})

    command_registry =
      start_supervised!({CommandRegistry, name: unique_name("git_extended_command_registry")})

    keymap = start_supervised!({ActiveKeymap, name: nil})
    path = Path.expand("../../lib", __DIR__)

    :ok = ExtRegistry.register(registry, :minga_git_extended, path, [])

    %{
      supervisor: supervisor,
      registry: registry,
      command_registry: command_registry,
      keymap: keymap
    }
  end

  defp expose_source_only! do
    # Mix loads compiled extension code for the other tests. Use only the extension source when testing install and reload.
    ebin = Application.app_dir(:minga_git_extended, "ebin") |> String.to_charlist()
    assert :code.del_path(ebin)
    on_exit(fn -> assert :code.add_patha(ebin) == true end)

    if ArtifactAdmission.source_modules(@source) == :error do
      for module <- Application.spec(:minga_git_extended, :modules), module != Dependencies do
        :code.delete(module)
        :code.purge(module)
      end
    end
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp runtime_supervisor(ctx) do
    registry = InstanceRegistry.registry_for_root(ctx.supervisor)
    InstanceRegistry.via(registry, :runtime, :minga_git_extended)
  end

  defp start_git_extended!(ctx) do
    {:ok, entry} = ExtRegistry.get(ctx.registry, :minga_git_extended)

    assert {:ok, pid} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :minga_git_extended,
               entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap,
               code_lease: @admission
             )

    pid
  end

  defp stop_git_extended!(ctx, callbacks \\ nil) do
    {:ok, entry} = ExtRegistry.get(ctx.registry, :minga_git_extended)

    opts = [
      command_registry: ctx.command_registry,
      keymap: ctx.keymap,
      code_lease: @admission
    ]

    opts = if callbacks == nil, do: opts, else: Keyword.put(opts, :callbacks, callbacks)

    assert :ok =
             ExtSupervisor.stop_extension(
               ctx.supervisor,
               ctx.registry,
               :minga_git_extended,
               entry,
               opts
             )
  end

  defp assert_git_extended_contributions_registered(ctx) do
    assert {:ok, _command} = CommandRegistry.lookup(ctx.command_registry, :git_status_toggle)
    assert {:ok, _command} = CommandRegistry.lookup(ctx.command_registry, :git_blame_line)
    assert {:command, :git_status_toggle, _description} = lookup_leader(ctx.keymap, "g g")
    assert {:command, :git_branch_picker, _description} = lookup_leader(ctx.keymap, "g b")
    assert {:command, :git_blame_line, _description} = lookup_leader(ctx.keymap, "g B")
    assert {:command, :git_stage_hunk, _description} = lookup_leader(ctx.keymap, "g s")
    assert %{semantic_kind: "git_status", source: @source} = Sidebar.get("git_status")
  end

  defp assert_git_extended_contributions_removed(ctx) do
    assert :error = CommandRegistry.lookup(ctx.command_registry, :git_status_toggle)
    assert :not_found = lookup_leader(ctx.keymap, "g g")
    assert Sidebar.get("git_status") == nil
  end

  defp lookup_leader(keymap, sequence) do
    {:ok, keys} = KeyParser.parse(sequence)

    keymap
    |> ActiveKeymap.leader_trie()
    |> Bindings.lookup_sequence(keys)
  end

  defp start_scheduler do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec(
          {EffectScheduler, task_supervisor: task_supervisor, observer: self()},
          id: make_ref()
        )
      )

    :ok = EffectScheduler.attach(scheduler, self())
    {scheduler, task_supervisor}
  end

  defp callbacks(scheduler) do
    %{
      editor_effects: &EffectScheduler.cancel_source(scheduler, &1),
      sidebars: &Sidebar.unregister_source/1
    }
  end

  defp running_task_ref(scheduler, request_id) do
    scheduler
    |> :sys.get_state()
    |> Map.fetch!(:lanes)
    |> Map.values()
    |> Enum.find_value(fn
      %{running: %{request: %{id: ^request_id}, task: task}} -> task.ref
      _lane -> nil
    end)
  end

  defp receive_candidate(scheduler, request_id, status) do
    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %{id: id}, value: {^status, _payload}} = outcome}
                   when id == request_id,
                   @timeout

    outcome
  end

  defp cleanup_git_extended_contributions do
    :ok = CommandRegistry.unregister_source(@source)
    :ok = ActiveKeymap.unregister_source(@source)
    :ok = Sidebar.unregister_source(@source)
    :ok = Sidebar.sync_git_status(Sidebar.default_table(), nil, false, false)
  end
end
