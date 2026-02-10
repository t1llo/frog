export namespace config {
	
	export class ActionConfig {
	    id: string;
	    name: string;
	    description: string;
	    systemPrompt: string;
	    userPrompt: string;
	    builtin: boolean;
	    icon: string;
	
	    static createFrom(source: any = {}) {
	        return new ActionConfig(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.name = source["name"];
	        this.description = source["description"];
	        this.systemPrompt = source["systemPrompt"];
	        this.userPrompt = source["userPrompt"];
	        this.builtin = source["builtin"];
	        this.icon = source["icon"];
	    }
	}
	export class GlobalHotkeyConfig {
	    id: string;
	    hotkey: string;
	    action: string;
	    category: string;
	    enabled: boolean;
	
	    static createFrom(source: any = {}) {
	        return new GlobalHotkeyConfig(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.hotkey = source["hotkey"];
	        this.action = source["action"];
	        this.category = source["category"];
	        this.enabled = source["enabled"];
	    }
	}
	export class TextProcessingConfig {
	    defaultLanguage: string;
	    translateTo: string;
	    actions: ActionConfig[];
	
	    static createFrom(source: any = {}) {
	        return new TextProcessingConfig(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.defaultLanguage = source["defaultLanguage"];
	        this.translateTo = source["translateTo"];
	        this.actions = this.convertValues(source["actions"], ActionConfig);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class ShortcutConfig {
	    id: string;
	    name: string;
	    hotkey: string;
	    appPath: string;
	    bundleId: string;
	    description: string;
	
	    static createFrom(source: any = {}) {
	        return new ShortcutConfig(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.name = source["name"];
	        this.hotkey = source["hotkey"];
	        this.appPath = source["appPath"];
	        this.bundleId = source["bundleId"];
	        this.description = source["description"];
	    }
	}
	export class RemoteProviderConfig {
	    id: string;
	    name: string;
	    type: string;
	    apiKey: string;
	    endpoint: string;
	    model: string;
	    active: boolean;
	
	    static createFrom(source: any = {}) {
	        return new RemoteProviderConfig(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.name = source["name"];
	        this.type = source["type"];
	        this.apiKey = source["apiKey"];
	        this.endpoint = source["endpoint"];
	        this.model = source["model"];
	        this.active = source["active"];
	    }
	}
	export class LocalLLMConfig {
	    modelId: string;
	    contextSize: number;
	    gpuLayers: number;
	
	    static createFrom(source: any = {}) {
	        return new LocalLLMConfig(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.modelId = source["modelId"];
	        this.contextSize = source["contextSize"];
	        this.gpuLayers = source["gpuLayers"];
	    }
	}
	export class LLMConfig {
	    activeProvider: string;
	    local: LocalLLMConfig;
	    remoteProviders: RemoteProviderConfig[];
	
	    static createFrom(source: any = {}) {
	        return new LLMConfig(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.activeProvider = source["activeProvider"];
	        this.local = this.convertValues(source["local"], LocalLLMConfig);
	        this.remoteProviders = this.convertValues(source["remoteProviders"], RemoteProviderConfig);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class Config {
	    llm: LLMConfig;
	    shortcuts: ShortcutConfig[];
	    textProcessing: TextProcessingConfig;
	    globalHotkeys: GlobalHotkeyConfig[];
	
	    static createFrom(source: any = {}) {
	        return new Config(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.llm = this.convertValues(source["llm"], LLMConfig);
	        this.shortcuts = this.convertValues(source["shortcuts"], ShortcutConfig);
	        this.textProcessing = this.convertValues(source["textProcessing"], TextProcessingConfig);
	        this.globalHotkeys = this.convertValues(source["globalHotkeys"], GlobalHotkeyConfig);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	
	
	
	
	

}

export namespace llm {
	
	export class DownloadStatus {
	    modelId: string;
	    fileName: string;
	    totalBytes: number;
	    doneBytes: number;
	    percent: number;
	    speed: string;
	    status: string;
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new DownloadStatus(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.modelId = source["modelId"];
	        this.fileName = source["fileName"];
	        this.totalBytes = source["totalBytes"];
	        this.doneBytes = source["doneBytes"];
	        this.percent = source["percent"];
	        this.speed = source["speed"];
	        this.status = source["status"];
	        this.error = source["error"];
	    }
	}
	export class LocalModel {
	    id: string;
	    name: string;
	    fileName: string;
	    filePath: string;
	    size: number;
	    sizeStr: string;
	
	    static createFrom(source: any = {}) {
	        return new LocalModel(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.name = source["name"];
	        this.fileName = source["fileName"];
	        this.filePath = source["filePath"];
	        this.size = source["size"];
	        this.sizeStr = source["sizeStr"];
	    }
	}
	export class ModelEntry {
	    id: string;
	    name: string;
	    description: string;
	    size: string;
	    parameters: string;
	    hfRepo: string;
	    hfFile: string;
	    downloadUrl: string;
	
	    static createFrom(source: any = {}) {
	        return new ModelEntry(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.name = source["name"];
	        this.description = source["description"];
	        this.size = source["size"];
	        this.parameters = source["parameters"];
	        this.hfRepo = source["hfRepo"];
	        this.hfFile = source["hfFile"];
	        this.downloadUrl = source["downloadUrl"];
	    }
	}
	export class ServerStatus {
	    running: boolean;
	    ready: boolean;
	    modelName: string;
	    modelPath: string;
	    port: number;
	    binaryFound: boolean;
	    error: string;
	
	    static createFrom(source: any = {}) {
	        return new ServerStatus(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.running = source["running"];
	        this.ready = source["ready"];
	        this.modelName = source["modelName"];
	        this.modelPath = source["modelPath"];
	        this.port = source["port"];
	        this.binaryFound = source["binaryFound"];
	        this.error = source["error"];
	    }
	}

}

export namespace shortcuts {
	
	export class AppInfo {
	    name: string;
	    path: string;
	    bundleId: string;
	
	    static createFrom(source: any = {}) {
	        return new AppInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.path = source["path"];
	        this.bundleId = source["bundleId"];
	    }
	}

}

