# Инструкции по валидации ToDo приложения с MySQL StatefulSet

Данный документ содержит подробные инструкции по развертыванию и валидации ToDo приложения с MySQL StatefulSet в Kubernetes кластере.

## Предварительные требования

Убедитесь, что у вас установлены следующие инструменты:

- **Docker** - для сборки образов контейнеров
- **kind** - для создания локального Kubernetes кластера
- **kubectl** - для управления Kubernetes кластером
- **Git** - для работы с репозиторием

### Установка инструментов

#### Docker

```bash
# Windows/Mac: Скачайте Docker Desktop с https://www.docker.com/products/docker-desktop
# Linux (Ubuntu/Debian):
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
```

#### kind

```bash
# Linux/Mac:
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Windows (PowerShell):
curl.exe -Lo kind-windows-amd64.exe https://kind.sigs.k8s.io/dl/v0.20.0/kind-windows-amd64.exe
Move-Item .\kind-windows-amd64.exe c:\some-dir-in-your-PATH\kind.exe
```

#### kubectl

```bash
# Linux:
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Windows (PowerShell):
curl.exe -LO "https://dl.k8s.io/release/v1.28.0/bin/windows/amd64/kubectl.exe"
```

## Развертывание

### Автоматическое развертывание

Выполните скрипт автоматического развертывания:

```bash
# Сделайте скрипт исполняемым
chmod +x bootstrap.sh

# Запустите развертывание
./bootstrap.sh
```

Скрипт автоматически выполнит:

1. Проверку необходимых инструментов
2. Проверку существования файлов манифестов
3. Создание Kind кластера
4. Создание необходимых namespace (mysql, todoapp)
5. Сборку Docker образа приложения
6. Развертывание MySQL в правильной последовательности:
   - Создание секретов MySQL
   - Создание ConfigMap для init.sql
   - Создание headless Service
   - Развертывание StatefulSet
7. Развертывание Django приложения в правильной последовательности:
   - Создание секретов для подключения к БД
   - Создание Service
   - Развертывание Deployment
8. Выполнение миграций базы данных
9. Отображение статуса развертывания

**Важные особенности скрипта:**

- **Идемпотентность**: Скрипт можно запускать несколько раз без проблем - он проверяет существование ресурсов перед их созданием
- **Правильная последовательность**: Все зависимости создаются в правильном порядке (namespace → secrets → services → deployments)
- **Встроенные манифесты**: Скрипт содержит все необходимые манифесты внутри себя, что исключает зависимость от внешних файлов
- **Подробное логирование**: Цветной вывод с детальной информацией о каждом шаге

### Ручное развертывание (альтернативный способ)

Если вы хотите выполнить развертывание вручную:

```bash
# 1. Создание кластера
kind create cluster --config=cluster.yml

# 2. Сборка и загрузка образа приложения
cd src
docker build -t todoapp:latest .
cd ..
kind load docker-image todoapp:latest

# 3. Развертывание MySQL StatefulSet
kubectl apply -f statefulSet.yml

# 4. Ожидание готовности MySQL
kubectl -n mysql rollout status statefulset/mysql --timeout=600s

# 5. Развертывание Django приложения
kubectl apply -f deployment.yml

# 6. Ожидание готовности приложения
kubectl -n todoapp rollout status deployment/todoapp --timeout=300s

# 7. Выполнение миграций
APP_POD=$(kubectl -n todoapp get pods -l app=todoapp -o jsonpath="{.items[0].metadata.name}")
kubectl -n todoapp exec $APP_POD -- python manage.py migrate
```

## Валидация развертывания

### 1. Проверка статуса кластера

```bash
# Проверка узлов кластера
kubectl get nodes

# Ожидаемый результат:
# NAME                 STATUS   ROLES           AGE   VERSION
# kind-control-plane   Ready    control-plane   5m    v1.27.3
# kind-worker          Ready    <none>          5m    v1.27.3
# kind-worker2         Ready    <none>          5m    v1.27.3
```

### 2. Проверка MySQL StatefulSet

```bash
# Проверка StatefulSet и подов
kubectl -n mysql get statefulset,pods,pvc,svc

# Ожидаемый результат:
# NAME                     READY   AGE
# statefulset.apps/mysql   3/3     5m

# NAME          READY   STATUS    RESTARTS   AGE
# pod/mysql-0   1/1     Running   0          5m
# pod/mysql-1   1/1     Running   0          4m
# pod/mysql-2   1/1     Running   0          3m

# Проверка persistent volumes
kubectl -n mysql get pvc

# Ожидаемый результат:
# NAME                               STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
# mysql-persistent-storage-mysql-0   Bound    pvc-xxx                                   10Gi       RWO            standard       5m
# mysql-persistent-storage-mysql-1   Bound    pvc-yyy                                   10Gi       RWO            standard       4m
# mysql-persistent-storage-mysql-2   Bound    pvc-zzz                                   10Gi       RWO            standard       3m
```

### 3. Проверка подключения к MySQL

```bash
# Подключение к первому поду MySQL
kubectl -n mysql exec -it mysql-0 -- mysql -u root -prootpassword

# Выполнение проверочных команд в MySQL:
# SHOW DATABASES;
# USE tododb;
# SHOW TABLES;
# SELECT USER();
# \q
```

### 4. Проверка Django приложения

```bash
# Проверка статуса Deployment
kubectl -n todoapp get deployment,pods,svc

# Ожидаемый результат:
# NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
# deployment.apps/todoapp   2/2     2            2           3m

# NAME                           READY   STATUS    RESTARTS   AGE
# pod/todoapp-xxx                1/1     Running   0          3m
# pod/todoapp-yyy                1/1     Running   0          3m

# Проверка логов приложения
kubectl -n todoapp logs -l app=todoapp --tail=50
```

### 5. Проверка сетевого подключения между приложением и базой данных

```bash
# Подключение к поду приложения
APP_POD=$(kubectl -n todoapp get pods -l app=todoapp -o jsonpath="{.items[0].metadata.name}")

# Проверка DNS резолюции MySQL
kubectl -n todoapp exec $APP_POD -- nslookup mysql-0.mysql-headless.mysql.svc.cluster.local

# Проверка подключения к MySQL порту
kubectl -n todoapp exec $APP_POD -- nc -zv mysql-0.mysql-headless.mysql.svc.cluster.local 3306
```

### 6. Проверка переменных окружения и секретов

```bash
# Проверка переменных окружения в поде приложения
kubectl -n todoapp exec $APP_POD -- env | grep DB_

# Ожидаемый результат:
# DB_NAME=tododb
# DB_USER=todouser
# DB_PASSWORD=todopassword
# DB_HOST=mysql-0.mysql-headless.mysql.svc.cluster.local
# DB_PORT=3306
```

### 7. Проверка работы веб-приложения

```bash
# Получение порта NodePort
NODE_PORT=$(kubectl -n todoapp get svc todoapp-service -o jsonpath='{.spec.ports[0].nodePort}')
echo "Приложение доступно на порту: $NODE_PORT"

# Проверка HTTP ответа
curl -I http://localhost:$NODE_PORT

# Ожидаемый результат:
# HTTP/1.1 200 OK
# Date: ...
# Server: WSGIServer/0.2 CPython/3.x.x
# Content-Type: text/html; charset=utf-8
```

### 8. Проверка Liveness и Readiness проб

```bash
# Проверка событий подов для просмотра статуса проб
kubectl -n mysql describe pods mysql-0 | grep -A5 -B5 "Liveness\|Readiness"
kubectl -n todoapp describe pods $APP_POD | grep -A5 -B5 "Liveness\|Readiness"

# Проверка метрик ресурсов
kubectl -n mysql top pods
kubectl -n todoapp top pods
```

### 9. Проверка persistent storage

```bash
# Проверка данных в MySQL после перезапуска
kubectl -n mysql delete pod mysql-0

# Ожидание восстановления
kubectl -n mysql wait --for=condition=Ready pod mysql-0 --timeout=300s

# Проверка сохранности данных
kubectl -n mysql exec mysql-0 -- mysql -u root -prootpassword -e "USE tododb; SHOW TABLES;"
```

### 10. Функциональная проверка приложения

```bash
# Port forwarding для локального доступа
kubectl -n todoapp port-forward svc/todoapp-service 8000:8000 &

# Откройте браузер и перейдите по адресу: http://localhost:8000

# Проверьте следующую функциональность:
# - Главная страница загружается
# - Регистрация нового пользователя
# - Авторизация
# - Создание задач
# - Редактирование задач
# - Удаление задач
# - API эндпоинты: http://localhost:8000/api/

# Остановка port forwarding
pkill -f "kubectl.*port-forward"
```

## Проверка требований задания

### ✅ StatefulSet требования:

1. **Namespace 'mysql'**: `kubectl get namespace mysql`
2. **3 реплики**: `kubectl -n mysql get statefulset mysql` (должно показать READY 3/3)
3. **Секреты из Secret**: `kubectl -n mysql describe statefulset mysql | grep -A10 "Environment"`
4. **Liveness и Readiness пробы**: `kubectl -n mysql describe statefulset mysql | grep -A5 "Liveness\|Readiness"`
5. **Resource requests/limits**: `kubectl -n mysql describe statefulset mysql | grep -A5 "Requests\|Limits"`
6. **Init.sql в /docker-entrypoint-initdb.d**: `kubectl -n mysql describe statefulset mysql | grep -A5 "Mounts"`
7. **VolumeClaimTemplates**: `kubectl -n mysql get pvc`
8. **Headless Service**: `kubectl -n mysql get svc mysql-headless`

### ✅ Deployment требования:

1. **Подключение к mysql-0**: Проверить переменную DB_HOST в поде приложения
2. **Чтение из Secret**: `kubectl -n todoapp describe deployment todoapp | grep -A10 "Environment"`

## Очистка ресурсов

```bash
# Удаление кластера Kind
kind delete cluster

# Удаление Docker образа
docker rmi todoapp:latest
```

## Устранение неполадок

### Проблема: Поды MySQL не запускаются

```bash
# Проверка событий
kubectl -n mysql describe pods mysql-0

# Проверка логов
kubectl -n mysql logs mysql-0

# Возможные причины:
# - Недостаточно ресурсов в кластере
# - Проблемы с PersistentVolume
# - Неправильные переменные окружения
```

### Проблема: Приложение не может подключиться к БД

```bash
# Проверка DNS
kubectl -n todoapp exec $APP_POD -- nslookup mysql-headless.mysql.svc.cluster.local

# Проверка сетевой связности
kubectl -n todoapp exec $APP_POD -- telnet mysql-0.mysql-headless.mysql.svc.cluster.local 3306

# Проверка переменных окружения
kubectl -n todoapp exec $APP_POD -- env | grep DB_
```

### Проблема: Ошибки при выполнении миграций

```bash
# Проверка логов приложения
kubectl -n todoapp logs -l app=todoapp

# Ручное выполнение миграций
kubectl -n todoapp exec $APP_POD -- python manage.py migrate --verbosity=2
```

## Мониторинг и логи

```bash
# Мониторинг логов MySQL
kubectl -n mysql logs -f statefulset/mysql

# Мониторинг логов приложения
kubectl -n todoapp logs -f deployment/todoapp

# Просмотр событий кластера
kubectl get events --sort-by=.metadata.creationTimestamp

# Проверка использования ресурсов
kubectl top nodes
kubectl top pods --all-namespaces
```

---

**Примечание**: Все команды тестировались в среде kind v0.20.0 с Kubernetes v1.27.3. При использовании других версий возможны незначительные отличия в выводе команд.
