const form = document.querySelector("#task-form");
const list = document.querySelector("#task-list");
const messageBox = document.querySelector("#message");
const refreshButton = document.querySelector("#refresh-button");

const statusLabels = new Map([
  ["pending", "待处理"],
  ["in_progress", "处理中"],
  ["completed", "已完成"],
]);

async function apiRequest(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  if (response.status === 204) return null;
  const body = await response.json().catch(() => ({
    error: { message: "服务器返回了无法解析的响应" },
  }));
  if (!response.ok) throw new Error(body.error?.message || "请求失败");
  return body;
}

function showMessage(message, isError = false) {
  messageBox.textContent = message;
  messageBox.dataset.state = isError ? "error" : "success";
}

function handleError(error) {
  showMessage(error.message, true);
}

async function updateTask(id, task, status) {
  await apiRequest(`/api/items/${id}`, {
    method: "PUT",
    body: JSON.stringify({
      title: task.title,
      description: task.description,
      status,
    }),
  });
  showMessage("任务状态已更新");
  await loadTasks();
}

async function deleteTask(id) {
  await apiRequest(`/api/items/${id}`, { method: "DELETE" });
  showMessage("任务已删除");
  await loadTasks();
}

function buildStatusSelect(task) {
  const select = document.createElement("select");
  select.className = `status-select status-${task.status}`;
  select.setAttribute("aria-label", `${task.title}的状态`);
  for (const [value, label] of statusLabels) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = label;
    option.selected = value === task.status;
    select.append(option);
  }
  select.addEventListener("change", () => {
    updateTask(task.id, task, select.value).catch(handleError);
  });
  return select;
}

function renderTasks(tasks) {
  list.replaceChildren();
  if (tasks.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = "暂无任务。创建第一条运维事项开始验证数据链路。";
    list.append(empty);
    return;
  }

  for (const task of tasks) {
    const row = document.createElement("article");
    row.className = "task-card";

    const taskId = document.createElement("span");
    taskId.className = "task-id";
    taskId.textContent = `TASK-${String(task.id).padStart(3, "0")}`;

    const title = document.createElement("h3");
    title.textContent = task.title;

    const description = document.createElement("p");
    description.className = "task-description";
    description.textContent = task.description;

    const actions = document.createElement("div");
    actions.className = "task-actions";
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "delete-button";
    remove.textContent = "删除";
    remove.addEventListener("click", () => deleteTask(task.id).catch(handleError));

    actions.append(buildStatusSelect(task), remove);
    row.append(taskId, title, description, actions);
    list.append(row);
  }
}

async function loadTasks() {
  refreshButton.disabled = true;
  try {
    renderTasks(await apiRequest("/api/items"));
  } finally {
    refreshButton.disabled = false;
  }
}

async function createTask(event) {
  event.preventDefault();
  const submit = form.querySelector('button[type="submit"]');
  submit.disabled = true;
  try {
    await apiRequest("/api/items", {
      method: "POST",
      body: JSON.stringify({
        title: form.elements.title.value,
        description: form.elements.description.value,
      }),
    });
    form.reset();
    showMessage("任务已创建");
    await loadTasks();
  } finally {
    submit.disabled = false;
  }
}

form.addEventListener("submit", (event) => createTask(event).catch(handleError));
refreshButton.addEventListener("click", () => loadTasks().catch(handleError));
loadTasks().catch(handleError);
