#!/usr/bin/env python3
"""
CDE Desktop Bridge - 最终完善版
功能：在CDE桌面中实现双击启动 .desktop 文件
特性：一键安装、安全执行、编码容错、文件大小限制
"""

import os
import sys
import re
import shlex
import time
import json
import logging
import subprocess
import configparser
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler, FileCreatedEvent, FileModifiedEvent

# ========== 配置区域 (用户可修改) ==========
CONFIG_FILE = Path.home() / ".config" / "cde-desktop-bridge.json"
DEFAULT_CONFIG = {
    "watch_dirs": [str(Path.home() / "Desktop")],
    "log_file": str(Path.home() / ".cde-desktop-bridge.log"),
    "session_check": True,
    "anti_flood_seconds": 3,
    "icon_theme": "Dtbfile",
    "max_file_size_kb": 10,  # 新增：最大文件大小限制(KB)
    "fallback_encodings": ["utf-8", "gbk", "gb2312", "latin-1"]  # 新增：备选编码列表
}
# =========================================

class ConfigManager:
    """配置文件管理器"""
    @staticmethod
    def load_config():
        if CONFIG_FILE.exists():
            with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
                user_config = json.load(f)
                config = DEFAULT_CONFIG.copy()
                config.update(user_config)
                return config
        return DEFAULT_CONFIG.copy()
    
    @staticmethod
    def save_config(config):
        CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
            json.dump(config, f, indent=2)

class DesktopFileParser:
    """.desktop文件解析器"""
    
    def __init__(self, config):
        self.config = config
        self.log = logging.getLogger(__name__)
    
    def parse(self, file_path):
        """解析.desktop文件，返回解析后的字典或None"""
        path = Path(file_path)
        
        try:
            # === 优化1: 检查文件大小 ===
            max_size = self.config.get('max_file_size_kb', 10) * 1024
            if path.stat().st_size > max_size:
                self.log.warning(f"文件过大({path.stat().st_size}字节)，跳过: {file_path}")
                return None
            
            # === 优化2: 编码容错读取 ===
            content = self._read_file_with_fallback(file_path)
            if content is None:
                self.log.error(f"无法解码文件编码: {file_path}")
                return None
            
            # 解析文件内容
            lines = content.split('\n')
            result = {'file_path': str(file_path)}
            in_desktop_entry = False
            
            for line in lines:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                
                if line == '[Desktop Entry]':
                    in_desktop_entry = True
                    continue
                elif line.startswith('[') and line.endswith(']'):
                    in_desktop_entry = False
                    continue
                
                if in_desktop_entry and '=' in line:
                    key, value = line.split('=', 1)
                    result[key] = value
            
            # 过滤不需要显示的文件
            if result.get('NoDisplay', '').lower() == 'true':
                self.log.info(f"NoDisplay=true，跳过: {file_path}")
                return None
            
            if result.get('Hidden', '').lower() == 'true':
                self.log.info(f"Hidden=true，跳过: {file_path}")
                return None
            
            # 必须有Exec字段
            if 'Exec' not in result:
                self.log.error(f"缺少Exec字段: {file_path}")
                return None
            
            # 处理占位符
            exec_cmd = self._process_placeholders(result, path)
            if not exec_cmd:
                return None
            
            result['Exec'] = exec_cmd
            return result
            
        except Exception as e:
            self.log.error(f"解析失败 {file_path}: {e}")
            return None
    
    def _read_file_with_fallback(self, file_path):
        """使用多种编码尝试读取文件"""
        encodings = self.config.get('fallback_encodings', DEFAULT_CONFIG['fallback_encodings'])
        
        for enc in encodings:
            try:
                with open(file_path, 'r', encoding=enc) as f:
                    return f.read()
            except UnicodeDecodeError:
                continue
            except Exception as e:
                logging.debug(f"编码{enc}读取失败: {e}")
                continue
        
        return None
    
    def _process_placeholders(self, result, file_path):
        """处理Exec命令中的占位符"""
        exec_cmd = result['Exec']
        desktop_name = file_path.stem
        
        # 构建占位符映射
        placeholders = {
            '%f': result.get('file_path', ''),
            '%F': result.get('file_path', ''),
            '%u': result.get('file_path', ''),
            '%U': result.get('file_path', ''),
            '%i': f"--icon '{result.get('Icon', '')}'" if result.get('Icon') else '',
            '%c': result.get('Name', desktop_name),
            '%k': str(file_path),
            '%d': '', '%D': '', '%n': '', '%N': '', '%v': '', '%m': ''
        }
        
        # 替换占位符
        for ph, val in placeholders.items():
            if ph in exec_cmd:
                exec_cmd = exec_cmd.replace(ph, str(val))
        
        # 清理多余空格但保留引号内容
        exec_cmd = ' '.join(exec_cmd.split())
        return exec_cmd

class DesktopFileLauncher:
    """.desktop文件启动器"""
    
    def __init__(self, config):
        self.config = config
        self.last_launch = {}
        self.log = logging.getLogger(__name__)
    
    def should_launch(self, file_path):
        """检查是否应该启动(防重复)"""
        current = time.time()
        file_str = str(file_path)
        
        if file_str in self.last_launch:
            elapsed = current - self.last_launch[file_str]
            if elapsed < self.config['anti_flood_seconds']:
                return False
        
        self.last_launch[file_str] = current
        return True
    
    def execute(self, desktop_info):
        """执行.desktop文件"""
        if not desktop_info:
            return False
        
        file_path = Path(desktop_info['file_path'])
        
        # 防重复检查
        if not self.should_launch(file_path):
            self.log.info(f"防重复: 跳过 {file_path.name}")
            return False
        
        # 环境检查
        if self.config.get('session_check', True):
            session = os.environ.get('DESKTOP_SESSION', '') + os.environ.get('XDG_CURRENT_DESKTOP', '')
            if 'CDE' not in session.upper():
                self.log.info(f"非CDE环境: {session}")
                return False
        
        try:
            # 设置工作目录
            working_dir = str(file_path.parent)
            if not working_dir or working_dir == '.':
                working_dir = os.getcwd()
            
            exec_cmd = desktop_info['Exec']
            self.log.info(f"执行: {exec_cmd}")
            
            # 安全执行(不使用shell=True)
            cmd_parts = shlex.split(exec_cmd)
            
            # 启动进程
            process = subprocess.Popen(
                cmd_parts,
                cwd=working_dir,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True
            )
            
            self.log.info(f"已启动 PID: {process.pid}")
            return True
            
        except Exception as e:
            self.log.error(f"执行失败 {file_path}: {e}")
            return False

class FileWatcher(FileSystemEventHandler):
    """文件监控处理器"""
    
    def __init__(self, launcher, parser):
        self.launcher = launcher
        self.parser = parser
        self.config = launcher.config
        super().__init__()
    
    def on_created(self, event):
        if not event.is_directory and event.src_path.endswith('.desktop'):
            self.process_file(event.src_path)
    
    def on_modified(self, event):
        if not event.is_directory and event.src_path.endswith('.desktop'):
            self.process_file(event.src_path)
    
    def process_file(self, file_path):
        """处理单个.desktop文件"""
        try:
            path = Path(file_path)
            
            # === 优化3: 文件大小检查(前置) ===
            max_size = self.config.get('max_file_size_kb', 10) * 1024
            if path.stat().st_size > max_size:
                self.launcher.log.warning(f"文件过大({path.stat().st_size}字节)，跳过: {file_path}")
                return
            
            # 解析并执行
            desktop_info = self.parser.parse(file_path)
            if desktop_info:
                self.launcher.execute(desktop_info)
                
        except Exception as e:
            self.launcher.log.error(f"处理文件失败 {file_path}: {e}")

class CDEInstaller:
    """CDE环境安装器"""
    
    @staticmethod
    def install():
        """一键安装: 创建所有必要的配置和文件"""
        config = ConfigManager.load_config()
        
        print("正在安装 CDE Desktop Bridge...")
        
        # 1. 保存配置
        ConfigManager.save_config(config)
        print(f"✓ 配置文件: {CONFIG_FILE}")
        
        # 2. 创建CDE动作文件
        action_content = f"""DATA_ATTRIBUTES DesktopFile
{{
    DESCRIPTION     "Freedesktop Desktop Entry"
    ICON            {config['icon_theme']}
    NAME_TEMPLATE   *.desktop
}}

DATA_CRITERIA DesktopCriteria
{{
    DATA_ATTRIBUTES_NAME DesktopFile
    MODE                 f
    NAME_PATTERN         *.desktop
}}

ACTION OpenDesktopFile
{{
    LABEL           "打开"
    TYPE            COMMAND
    EXEC_STRING     {sys.executable} {os.path.abspath(__file__)} --execute "%Arg_1%"
    WINDOW_TYPE     NO_STDIO
    DESCRIPTION     "使用桥接器打开.desktop文件"
}}
"""
        
        action_dir = Path.home() / ".dt" / "types"
        action_dir.mkdir(parents=True, exist_ok=True)
        action_file = action_dir / "DesktopFile.dt"
        
        with open(action_file, 'w', encoding='utf-8') as f:
            f.write(action_content)
        print(f"✓ CDE动作文件: {action_file}")
        
        # 3. 创建systemd服务
        service_content = f"""[Unit]
Description=CDE Desktop File Bridge Daemon
After=graphical-session.target
ConditionEnvironment=DESKTOP_SESSION=CDE

[Service]
Type=simple
ExecStart={sys.executable} {os.path.abspath(__file__)} --daemon
Restart=on-failure
RestartSec=5
Environment=DISPLAY=:0

[Install]
WantedBy=default.target
"""
        
        service_dir = Path.home() / ".config" / "systemd" / "user"
        service_dir.mkdir(parents=True, exist_ok=True)
        service_file = service_dir / "cde-desktop-bridge.service"
        
        with open(service_file, 'w', encoding='utf-8') as f:
            f.write(service_content)
        print(f"✓ Systemd服务: {service_file}")
        
        # 4. 启用服务
        try:
            subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True, 
                         capture_output=True, text=True)
            subprocess.run(['systemctl', '--user', 'enable', 'cde-desktop-bridge.service'], 
                         check=True, capture_output=True, text=True)
            subprocess.run(['systemctl', '--user', 'start', 'cde-desktop-bridge.service'], 
                         check=True, capture_output=True, text=True)
            print("✓ Systemd服务已启用并启动")
        except subprocess.CalledProcessError as e:
            print(f"⚠ 服务启用可能需要手动操作，错误: {e.stderr}")
        
        # 5. 设置日志
        logging.basicConfig(
            level=logging.INFO,
            format='[%(asctime)s] %(levelname)s: %(message)s',
            handlers=[
                logging.FileHandler(config['log_file'], encoding='utf-8'),
                logging.StreamHandler()
            ]
        )
        
        print("\n" + "="*50)
        print("✅ 安装完成!")
        print("="*50)
        print(f"日志文件: {config['log_file']}")
        print(f"监控目录: {', '.join(config['watch_dirs'])}")
        print(f"最大文件: {config.get('max_file_size_kb', 10)}KB")
        print(f"备选编码: {', '.join(config.get('fallback_encodings', ['utf-8']))}")
        print("\n下次登录CDE桌面后，双击.desktop文件即可启动应用。")

def run_daemon():
    """运行守护进程"""
    config = ConfigManager.load_config()
    
    # 设置日志
    logging.basicConfig(
        level=logging.INFO,
        format='[%(asctime)s] %(levelname)s: %(message)s',
        handlers=[
            logging.FileHandler(config['log_file'], encoding='utf-8'),
        ]
    )
    
    log = logging.getLogger(__name__)
    log.info("=== CDE Desktop Bridge 启动 ===")
    
    # 环境检查
    if config.get('session_check', True):
        session = os.environ.get('DESKTOP_SESSION', '') + os.environ.get('XDG_CURRENT_DESKTOP', '')
        if 'CDE' not in session.upper():
            log.info(f"非CDE环境 ({session})，退出")
            return
    
    # 初始化组件
    parser = DesktopFileParser(config)
    launcher = DesktopFileLauncher(config)
    watcher = FileWatcher(launcher, parser)
    observer = Observer()
    
    # 添加监控目录
    valid_dirs = []
    for watch_dir in config['watch_dirs']:
        path = Path(watch_dir)
        if path.exists():
            observer.schedule(watcher, str(path), recursive=False)
            valid_dirs.append(str(path))
            log.info(f"监控目录: {path}")
    
    if not valid_dirs:
        log.error("没有有效的监控目录，退出")
        return
    
    observer.start()
    log.info(f"守护进程运行中，监控{len(valid_dirs)}个目录...")
    
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
        observer.join()
        log.info("守护进程停止")
    except Exception as e:
        log.error(f"守护进程异常: {e}")

def execute_file(file_path):
    """执行单个文件"""
    config = ConfigManager.load_config()
    
    logging.basicConfig(
        level=logging.INFO,
        format='[%(asctime)s] %(levelname)s: %(message)s'
    )
    
    log = logging.getLogger(__name__)
    
    parser = DesktopFileParser(config)
    launcher = DesktopFileLauncher(config)
    
    desktop_info = parser.parse(Path(file_path))
    if desktop_info:
        launcher.execute(desktop_info)
        log.info(f"执行完成: {file_path}")
    else:
        log.error(f"无法解析或执行: {file_path}")

def main():
    """主函数"""
    if len(sys.argv) > 1:
        if sys.argv[1] == '--install':
            CDEInstaller.install()
        elif sys.argv[1] == '--daemon':
            run_daemon()
        elif sys.argv[1] == '--execute' and len(sys.argv) > 2:
            execute_file(sys.argv[2])
        elif sys.argv[1] == '--config':
            config = ConfigManager.load_config()
            print(json.dumps(config, indent=2))
        elif sys.argv[1] == '--help':
            print("""
CDE Desktop Bridge - 在CDE中启动.desktop文件
用法:
  --install        一键安装(配置、动作、服务)
  --daemon         运行守护进程
  --execute FILE   执行单个.desktop文件
  --config         显示当前配置
  --help           显示此帮助
无参数             显示帮助

特性:
  • 支持多种文件编码(utf-8, gbk, gb2312, latin-1)
  • 自动过滤NoDisplay/Hidden文件
  • 防重复启动机制
  • 文件大小限制(默认10KB)
  • 安全命令执行
            """)
        else:
            print(f"未知参数: {sys.argv[1]}")
            print("使用 --help 查看帮助")
    else:
        print("使用 --install 进行一键安装")
        print("使用 --help 查看完整帮助")

if __name__ == "__main__":
    main()
