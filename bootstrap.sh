#!/bin/bash

# Bootstrap script для развертывания ToDo приложения с MySQL StatefulSet в Kubernetes
set -e

echo "🚀 Начинаем развертывание ToDo приложения с MySQL StatefulSet..."

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для логирования
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка наличия необходимых инструментов
check_prerequisites() {
    log_info "Проверка необходимых инструментов..."
    
    if ! command -v kind &> /dev/null; then
        log_error "kind не установлен. Установите kind: https://kind.sigs.k8s.io/docs/user/quick-start/"
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl не установлен. Установите kubectl: https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi
    
    if ! command -v docker &> /dev/null; then
        log_error "docker не установлен. Установите Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi
    
    log_success "Все необходимые инструменты установлены"
}

# Создание кластера Kind
create_cluster() {
    log_info "Создание кластера Kind..."
    
    if kind get clusters | grep -q "kind"; then
        log_warning "Кластер Kind уже существует"
        read -p "Хотите пересоздать кластер? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Удаление существующего кластера..."
            kind delete cluster
        else
            log_info "Используем существующий кластер"
            return 0
        fi
    fi
    
    log_info "Создание нового кластера из cluster.yml..."
    kind create cluster --config=cluster.yml
    
    # Ждем готовности кластера
    log_info "Ожидание готовности кластера..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    log_success "Кластер Kind создан и готов"
}

# Сборка Docker образа приложения
build_app_image() {
    log_info "Сборка Docker образа приложения..."
    
    cd src
    docker build -t todoapp:latest .
    cd ..
    
    # Загрузка образа в Kind кластер
    log_info "Загрузка образа в Kind кластер..."
    kind load docker-image todoapp:latest
    
    log_success "Docker образ собран и загружен в кластер"
}

# Создание необходимых namespace
create_namespaces() {
    log_info "Создание необходимых namespace..."
    
    # Создаем namespace mysql если не существует
    if ! kubectl get namespace mysql >/dev/null 2>&1; then
        log_info "Создание namespace mysql..."
        kubectl create namespace mysql
    else
        log_info "Namespace mysql уже существует"
    fi
    
    # Создаем namespace todoapp если не существует
    if ! kubectl get namespace todoapp >/dev/null 2>&1; then
        log_info "Создание namespace todoapp..."
        kubectl create namespace todoapp
    else
        log_info "Namespace todoapp уже существует"
    fi
    
    log_success "Все необходимые namespace созданы"
}

# Создание секретов для MySQL
create_mysql_secrets() {
    log_info "Создание секретов для MySQL..."
    
    # Проверяем существование секрета
    if ! kubectl -n mysql get secret mysql-secret >/dev/null 2>&1; then
        log_info "Создание Secret mysql-secret..."
        kubectl -n mysql create secret generic mysql-secret \
            --from-literal=MYSQL_ROOT_PASSWORD=rootpassword \
            --from-literal=MYSQL_USER=todouser \
            --from-literal=MYSQL_PASSWORD=todopassword
    else
        log_info "Secret mysql-secret уже существует"
    fi
    
    log_success "Секреты MySQL созданы"
}

# Создание ConfigMap для init.sql
create_mysql_configmap() {
    log_info "Создание ConfigMap для init.sql..."
    
    # Создаем временный файл с init.sql
    cat > /tmp/init.sql << 'EOF'
CREATE DATABASE IF NOT EXISTS tododb;
USE tododb;

-- Создание таблиц для Django приложения
CREATE TABLE IF NOT EXISTS auth_user (
    id INT AUTO_INCREMENT PRIMARY KEY,
    password VARCHAR(128) NOT NULL,
    last_login DATETIME(6),
    is_superuser TINYINT(1) NOT NULL,
    username VARCHAR(150) NOT NULL UNIQUE,
    first_name VARCHAR(150) NOT NULL,
    last_name VARCHAR(150) NOT NULL,
    email VARCHAR(254) NOT NULL,
    is_staff TINYINT(1) NOT NULL,
    is_active TINYINT(1) NOT NULL,
    date_joined DATETIME(6) NOT NULL
);

-- Предоставление прав пользователю
GRANT ALL PRIVILEGES ON tododb.* TO 'todouser'@'%';
FLUSH PRIVILEGES;
EOF

    # Проверяем существование ConfigMap
    if ! kubectl -n mysql get configmap mysql-init-config >/dev/null 2>&1; then
        log_info "Создание ConfigMap mysql-init-config..."
        kubectl -n mysql create configmap mysql-init-config --from-file=init.sql=/tmp/init.sql
    else
        log_info "ConfigMap mysql-init-config уже существует"
    fi
    
    # Удаляем временный файл
    rm -f /tmp/init.sql
    
    log_success "ConfigMap для init.sql создан"
}

# Создание headless Service для MySQL
create_mysql_service() {
    log_info "Создание headless Service для MySQL..."
    
    # Проверяем существование сервиса
    if ! kubectl -n mysql get service mysql-headless >/dev/null 2>&1; then
        log_info "Создание Service mysql-headless..."
        kubectl -n mysql create service clusterip mysql-headless --tcp=3306:3306 --clusterip=None
        kubectl -n mysql label service mysql-headless app=mysql
    else
        log_info "Service mysql-headless уже существует"
    fi
    
    log_success "Headless Service для MySQL создан"
}

# Развертывание MySQL StatefulSet
deploy_mysql_statefulset() {
    log_info "Развертывание MySQL StatefulSet..."
    
    # Создаем временный файл с манифестом StatefulSet
    cat > /tmp/mysql-statefulset.yml << 'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
  namespace: mysql
spec:
  serviceName: mysql-headless
  replicas: 3
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: MYSQL_ROOT_PASSWORD
        - name: MYSQL_USER
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: MYSQL_USER
        - name: MYSQL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: MYSQL_PASSWORD
        - name: MYSQL_DATABASE
          value: tododb
        ports:
        - containerPort: 3306
          name: mysql
        # Liveness Probe - проверяет, жив ли контейнер
        livenessProbe:
          exec:
            command:
            - mysqladmin
            - ping
            - -h
            - localhost
            - -u
            - root
            - -p$(MYSQL_ROOT_PASSWORD)
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        # Readiness Probe - проверяет, готов ли контейнер принимать трафик
        readinessProbe:
          exec:
            command:
            - mysql
            - -h
            - localhost
            - -u
            - root
            - -p$(MYSQL_ROOT_PASSWORD)
            - -e
            - "SELECT 1"
          initialDelaySeconds: 5
          periodSeconds: 2
          timeoutSeconds: 1
        # Resource requests и limits
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        # Монтирование init.sql
        volumeMounts:
        - name: mysql-persistent-storage
          mountPath: /var/lib/mysql
        - name: mysql-init-volume
          mountPath: /docker-entrypoint-initdb.d
      volumes:
      - name: mysql-init-volume
        configMap:
          name: mysql-init-config
  # Volume Claim Templates для persistent storage
  volumeClaimTemplates:
  - metadata:
      name: mysql-persistent-storage
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 10Gi
EOF

    # Применяем манифест StatefulSet
    kubectl apply -f /tmp/mysql-statefulset.yml
    
    # Удаляем временный файл
    rm -f /tmp/mysql-statefulset.yml
    
    # Ждем готовности StatefulSet
    log_info "Ожидание готовности MySQL StatefulSet..."
    kubectl -n mysql rollout status statefulset/mysql --timeout=600s
    
    # Проверяем, что все поды готовы
    kubectl -n mysql wait --for=condition=Ready pod --all --timeout=300s
    
    log_success "MySQL StatefulSet развернут и готов"
}

# Полное развертывание MySQL (объединяющая функция)
deploy_mysql() {
    log_info "Начинаем развертывание MySQL..."
    create_mysql_secrets
    create_mysql_configmap
    create_mysql_service
    deploy_mysql_statefulset
    log_success "MySQL полностью развернут"
}

# Создание секретов для Django приложения
create_app_secrets() {
    log_info "Создание секретов для Django приложения..."
    
    # Проверяем существование секрета для БД
    if ! kubectl -n todoapp get secret todoapp-db-secret >/dev/null 2>&1; then
        log_info "Создание Secret todoapp-db-secret..."
        kubectl -n todoapp create secret generic todoapp-db-secret \
            --from-literal=NAME=tododb \
            --from-literal=USER=todouser \
            --from-literal=PASSWORD=todopassword \
            --from-literal=HOST=mysql-0.mysql-headless.mysql.svc.cluster.local
    else
        log_info "Secret todoapp-db-secret уже существует"
    fi
    
    log_success "Секреты для Django приложения созданы"
}

# Создание Service для Django приложения
create_app_service() {
    log_info "Создание Service для Django приложения..."
    
    # Проверяем существование сервиса
    if ! kubectl -n todoapp get service todoapp-service >/dev/null 2>&1; then
        log_info "Создание Service todoapp-service..."
        kubectl -n todoapp create service nodeport todoapp-service --tcp=8000:8000 --node-port=30007
        kubectl -n todoapp label service todoapp-service app=todoapp
    else
        log_info "Service todoapp-service уже существует"
    fi
    
    log_success "Service для Django приложения создан"
}

# Развертывание Django Deployment
deploy_app_deployment() {
    log_info "Развертывание Django Deployment..."
    
    # Создаем временный файл с манифестом Deployment
    cat > /tmp/django-deployment.yml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: todoapp
  namespace: todoapp
  labels:
    app: todoapp
spec:
  replicas: 2
  selector:
    matchLabels:
      app: todoapp
  template:
    metadata:
      labels:
        app: todoapp
    spec:
      containers:
      - name: todoapp
        image: todoapp:latest
        imagePullPolicy: Never  # Для локальной разработки с kind
        ports:
        - containerPort: 8000
        env:
        - name: DB_NAME
          valueFrom:
            secretKeyRef:
              name: todoapp-db-secret
              key: NAME
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: todoapp-db-secret
              key: USER
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: todoapp-db-secret
              key: PASSWORD
        - name: DB_HOST
          valueFrom:
            secretKeyRef:
              name: todoapp-db-secret
              key: HOST
        - name: DB_PORT
          value: "3306"
        - name: SECRET_KEY
          value: "django-insecure-development-key-change-in-production"
        # Liveness Probe
        livenessProbe:
          httpGet:
            path: /
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        # Readiness Probe
        readinessProbe:
          httpGet:
            path: /
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
        # Resource requests и limits
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
EOF

    # Применяем манифест Deployment
    kubectl apply -f /tmp/django-deployment.yml
    
    # Удаляем временный файл
    rm -f /tmp/django-deployment.yml
    
    # Ждем готовности Deployment
    log_info "Ожидание готовности Django приложения..."
    kubectl -n todoapp rollout status deployment/todoapp --timeout=300s
    
    # Проверяем, что все поды готовы
    kubectl -n todoapp wait --for=condition=Ready pod --all --timeout=300s
    
    log_success "Django Deployment развернут и готов"
}

# Полное развертывание Django приложения (объединяющая функция)
deploy_app() {
    log_info "Начинаем развертывание Django приложения..."
    create_app_secrets
    create_app_service
    deploy_app_deployment
    log_success "Django приложение полностью развернуто"
}

# Выполнение миграций Django
run_migrations() {
    log_info "Выполнение миграций Django..."
    
    # Получаем имя первого пода приложения
    APP_POD=$(kubectl -n todoapp get pods -l app=todoapp -o jsonpath="{.items[0].metadata.name}")
    
    if [ -z "$APP_POD" ]; then
        log_error "Не найден под приложения для выполнения миграций"
        exit 1
    fi
    
    # Выполняем миграции
    log_info "Выполнение миграций в поде $APP_POD..."
    kubectl -n todoapp exec $APP_POD -- python manage.py migrate
    
    log_success "Миграции выполнены успешно"
}

# Показ статуса развертывания
show_status() {
    log_info "Статус развертывания:"
    
    echo
    echo "=== MySQL StatefulSet ==="
    kubectl -n mysql get statefulset,pods,pvc,svc
    
    echo
    echo "=== Django Application ==="
    kubectl -n todoapp get deployment,pods,svc
    
    echo
    echo "=== Доступ к приложению ==="
    NODE_PORT=$(kubectl -n todoapp get svc todoapp-service -o jsonpath='{.spec.ports[0].nodePort}')
    log_success "Приложение доступно по адресу: http://localhost:$NODE_PORT"
}

# Проверка существования файлов манифестов
check_manifest_files() {
    log_info "Проверка существования файлов манифестов..."
    
    local missing_files=()
    
    # Проверяем необходимые файлы (опционально, если хотим использовать статические файлы)
    # if [[ ! -f "statefulSet.yml" ]]; then
    #     missing_files+=("statefulSet.yml")
    # fi
    
    # if [[ ! -f "deployment.yml" ]]; then
    #     missing_files+=("deployment.yml")
    # fi
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        log_warning "Некоторые файлы манифестов отсутствуют: ${missing_files[*]}"
        log_info "Будут использованы встроенные манифесты из скрипта"
    fi
    
    log_success "Проверка файлов завершена"
}

# Основная функция
main() {
    echo "=================================="
    echo "  ToDo App с MySQL StatefulSet"
    echo "=================================="
    echo
    
    check_prerequisites
    check_manifest_files
    create_cluster
    create_namespaces  # Создаем namespace перед всем остальным
    build_app_image
    deploy_mysql
    deploy_app
    
    # Небольшая пауза перед выполнением миграций
    log_info "Ожидание стабилизации приложения..."
    sleep 30
    
    run_migrations
    show_status
    
    echo
    log_success "🎉 Развертывание завершено успешно!"
    echo
    echo "Для проверки работы приложения выполните:"
    echo "  kubectl -n todoapp port-forward svc/todoapp-service 8000:8000"
    echo "  Затем откройте http://localhost:8000"
    echo
    echo "Для мониторинга логов:"
    echo "  kubectl -n mysql logs -f statefulset/mysql"
    echo "  kubectl -n todoapp logs -f deployment/todoapp"
}

# Запуск основной функции
main "$@"